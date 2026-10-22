import AVFoundation
import Foundation
import VideoToolbox

public struct MediaError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Reads files with AVFoundation.
public struct AVProbe: MediaProbing {
    public init() {}

    public func source(of url: URL) async throws -> VideoSource {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video?.load(.naturalSize) ?? .zero
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return VideoSource(
            seconds: duration.seconds, width: Int(abs(size.width)), height: Int(abs(size.height)), bytes: bytes,
            hasAudio: !audio.isEmpty)
    }

    public func playable(_ url: URL, seconds: Double?) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let duration = try? await asset.load(.duration),
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty
        else { return false }
        guard let seconds else { return duration.seconds > 0 }
        return abs(duration.seconds - seconds) <= max(1, seconds * 0.02)
    }
}

/// H.264 MP4 through AVAssetWriter, on the hardware encoder where the Mac has
/// one. Keeps the source's rotation as metadata, so a portrait iPhone video
/// stays portrait, and mixes every audio track (screen: Mac and microphone).
public struct AssetWriterEncoder: VideoEncoder {
    public init() {}

    public func encode(
        _ input: URL, to output: URL, settings: EncodeSettings, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError("Dit bestand heeft geen beeld.")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let fps = try await video.load(.nominalFrameRate)
        let size = settings.dimensions(sourceWidth: Int(abs(natural.width)), sourceHeight: Int(abs(natural.height)))

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitsPerSecond,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if fps > 0 { compression[AVVideoExpectedSourceFrameRateKey] = fps }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioPair: (AVAssetReaderAudioMixOutput, AVAssetWriterInput)?
        if !audioTracks.isEmpty, settings.audioBitsPerSecond > 0 {
            let channels = settings.audioBitsPerSecond > 64_000 ? 2 : 1
            let pair = Self.audio(tracks: audioTracks, channels: channels, bitsPerSecond: settings.audioBitsPerSecond)
            reader.add(pair.0)
            writer.add(pair.1)
            audioPair = pair
        }
        try await Self.run(reader: reader, writer: writer, duration: duration, video: (videoOut, videoIn), audio: audioPair, progress: progress)
    }

    static func audio(tracks: [AVAssetTrack], channels: Int, bitsPerSecond: Int) -> (AVAssetReaderAudioMixOutput, AVAssetWriterInput) {
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitsPerSecond,
        ])
        input.expectsMediaDataInRealTime = false
        return (out, input)
    }

    /// Copies every sample from the reader's outputs to the writer's inputs,
    /// both tracks at once, and finishes the file. Cancelling the task stops
    /// it and leaves no half file behind.
    static func run(
        reader: AVAssetReader, writer: AVAssetWriter, duration: Double,
        video: (AVAssetReaderOutput, AVAssetWriterInput)?, audio: (AVAssetReaderOutput, AVAssetWriterInput)?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard reader.startReading() else { throw reader.error ?? MediaError("Kon het bestand niet lezen.") }
        guard writer.startWriting() else { throw writer.error ?? MediaError("Kon het nieuwe bestand niet schrijven.") }
        writer.startSession(atSourceTime: .zero)
        let report: (CMTime) -> Void = { time in
            if duration > 0 { progress(min(1, max(0, time.seconds / duration))) }
        }
        nonisolated(unsafe) let cancellable = reader
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                if let video {
                    group.addTask { await pump(video.0, into: video.1, label: "video", onTime: report) }
                }
                if let audio {
                    group.addTask { await pump(audio.0, into: audio.1, label: "audio", onTime: nil) }
                }
            }
        } onCancel: {
            cancellable.cancelReading()
        }
        if Task.isCancelled || reader.status == .failed || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            if Task.isCancelled { throw CancellationError() }
            throw reader.error ?? MediaError("Het lezen stopte halverwege.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: writer.outputURL)
            throw writer.error ?? MediaError("Het nieuwe bestand is niet afgemaakt.")
        }
        progress(1)
    }

    private static func pump(
        _ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String, onTime: ((CMTime) -> Void)?
    ) async {
        let queue = DispatchQueue(label: "app.burrow.pensieve.encode.\(label)")
        // Only ever touched on `queue`.
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, !finished {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        finished = true
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                    onTime?(CMSampleBufferGetPresentationTimeStamp(buffer))
                }
            }
        }
    }
}

/// The sound of a video as `audio.m4a`: every audio track mixed to mono AAC,
/// for the server to transcribe without the video ever leaving the Mac.
public enum AudioExtractor {
    public static func extract(from input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MediaError("Deze opname heeft geen geluid.") }
        let duration = try await asset.load(.duration).seconds
        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let pair = AssetWriterEncoder.audio(tracks: tracks, channels: 1, bitsPerSecond: 64_000)
        reader.add(pair.0)
        writer.add(pair.1)
        try await AssetWriterEncoder.run(reader: reader, writer: writer, duration: duration, video: nil, audio: pair, progress: { _ in })
    }
}
