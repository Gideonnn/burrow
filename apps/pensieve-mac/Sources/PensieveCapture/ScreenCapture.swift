import AVFoundation
import Foundation
import ScreenCaptureKit

// The screen plus everything the Mac plays, and the microphone when asked:
// ScreenCaptureKit writes it straight to a movie file (SCRecordingOutput,
// macOS 15). The app compresses it after Stop, like a webcam video.

@available(macOS 15.0, *)
public final class ScreenCapture: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  public let url: URL
  private var stream: SCStream?
  private var recording: SCRecordingOutput?
  // Set on stop, resumed from ScreenCaptureKit's queue; guarded by `lock`.
  private var finished: CheckedContinuation<URL, Error>?
  private var failure: Error?
  private let lock = NSLock()
  public private(set) var started: Date?

  public init(url: URL) {
    self.url = url
  }

  /// The displays to choose from; asking also triggers the permission prompt.
  public static func displays() async throws -> [SCDisplay] {
    try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
  }

  /// Records `display` (the main one when nil), without Pensieve's own
  /// windows. `microphone` is a CoreAudio uid, or nil for no microphone.
  public func start(display: CGDirectDisplayID? = nil, microphone: String?) async throws {
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
      throw CaptureError("Pensieve mag het scherm niet opnemen. Zet het aan in Systeeminstellingen › Privacy en beveiliging › Scherm- en systeemaudio-opname.")
    }
    guard let screen = content.displays.first(where: { $0.displayID == display }) ?? content.displays.first else {
      throw CaptureError("Er is geen scherm gevonden.")
    }
    let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
    let filter = SCContentFilter(display: screen, excludingApplications: own, exceptingWindows: [])

    let config = SCStreamConfiguration()
    // Retina pixels; compression brings it to the chosen size afterwards.
    let scale = Int(filter.pointPixelScale)
    config.width = Int(filter.contentRect.width) * max(scale, 1)
    config.height = Int(filter.contentRect.height) * max(scale, 1)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.showsCursor = true
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.captureMicrophone = microphone != nil
    if let microphone { config.microphoneCaptureDeviceID = microphone }

    let output = SCRecordingOutputConfiguration()
    output.outputURL = url
    output.outputFileType = .mov
    output.videoCodecType = .h264

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    let recording = SCRecordingOutput(configuration: output, delegate: self)
    try stream.addRecordingOutput(recording)
    try await stream.startCapture()
    self.stream = stream
    self.recording = recording
    started = Date()
  }

  public var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }

  /// Stops and waits until the file is complete.
  public func stop() async throws -> URL {
    guard let stream else { throw lock.withLock { failure } ?? CaptureError("Er loopt geen schermopname.") }
    self.stream = nil
    return try await withCheckedThrowingContinuation { continuation in
      lock.withLock { finished = continuation }
      Task {
        do { try await stream.stopCapture() } catch { self.finish(.failure(error)) }
      }
    }
  }

  private func finish(_ result: Result<URL, Error>) {
    let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
      if case .failure(let error) = result { failure = error }
      defer { finished = nil }
      return finished
    }
    continuation?.resume(with: result)
  }

  public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    finish(.success(url))
  }

  public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    finish(.failure(error))
  }

  public func stream(_ stream: SCStream, didStopWithError error: Error) {
    finish(.failure(error))
  }
}

@available(macOS 15.0, *)
extension ScreenCapture: @unchecked Sendable {}
