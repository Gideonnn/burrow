import AVFoundation
import CoreAudio
import Foundation

// The recorder, from RecHoarder. One private aggregate device carries the chosen microphone and
// a process tap of everything the Mac plays, so a single IOProc hands over both
// halves of the call sample-aligned, mixed here into a 16 kHz mono WAV.
//
// No device the user can see is created and no default is touched: the tap
// reads the output stream wherever it goes, the aggregate is private, and both
// are destroyed when the recording stops. The microphone is the clock master
// and the tap gets drift compensation, so a Bluetooth headset does not drift
// against the far end over a long meeting.

public struct Levels: Sendable {
  public init(mic: Double = -120, call: Double = -120, micDead: Bool = false, callSilent: Bool = false) {
    self.mic = mic
    self.call = call
    self.micDead = micDead
    self.callSilent = callSilent
  }

  public var mic = -120.0
  public var call = -120.0
  // Exact zeros for seconds on end are not a quiet room: real hardware always
  // dithers something. That is what a denied capture looks like.
  public var micDead = false
  public var callSilent = false
}

public final class Recorder {
  public static let fileRate = 16_000.0
  private static let silenceGrace = 2.0

  public let microphone: Device
  public let url: URL
  public let started = Date()

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private let micBuffers: Int
  private let sampleRate: Double

  private let file: AVAudioFile
  private let converter: AVAudioConverter
  private let inputFormat: AVAudioFormat
  private let writer = DispatchQueue(label: "app.burrow.pensieve.writer")
  private var framesWritten: AVAudioFramePosition = 0

  private let lock = NSLock()
  private var micPeak: Float = 0
  private var callPeak: Float = 0
  private var micSawSignal = false
  private var callSawSignal = false
  private var lastBuffer = Date.distantPast
  private(set) var debugPeaks: (mic: Float, call: Float) = (0, 0)
  var debugStreams: [Int] { streamChannels(aggregateID, scope: kAudioObjectPropertyScopeInput) }

  public init(microphone: Device, url: URL) throws {
    self.microphone = microphone
    self.url = url

    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.name = "Pensieve"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
      throw CaptureError("Kon het systeemgeluid niet aftappen. Geef Pensieve toegang tot systeemaudio in Systeeminstellingen > Privacy en beveiliging.")
    }
    tapID = tap
    guard let tapUID = propertyString(tap, address(kAudioTapPropertyUID)) else {
      AudioHardwareDestroyProcessTap(tap)
      throw CaptureError("De systeemaudio-tap heeft geen UID.")
    }

    // Key strings spelled out: the SDK constants have been renamed across
    // releases while the strings underneath never changed.
    let config: [String: Any] = [
      "name": "Pensieve",
      "uid": "app.burrow.pensieve.capture",
      "private": true,
      "stacked": false,
      "tapautostart": true,
      "master": microphone.uid,
      "subdevices": [["uid": microphone.uid]],
      "taps": [["uid": tapUID, "drift": true]],
    ]
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate) == noErr else {
      AudioHardwareDestroyProcessTap(tap)
      throw CaptureError("Kon geen opnameapparaat maken rond \(microphone.name).")
    }
    aggregateID = aggregate

    // The aggregate hands over one buffer per stream, sub-devices first, then
    // taps. The microphone's own stream count says where the tap begins.
    micBuffers = streamChannels(microphone.id, scope: kAudioObjectPropertyScopeInput).count
    guard let asbd = propertyFormat(aggregate, address(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput)),
          asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mSampleRate > 0 else {
      Self.destroy(aggregate: aggregate, tap: tap)
      throw CaptureError("\(microphone.name) levert geen bruikbaar geluidsformaat.")
    }
    sampleRate = asbd.mSampleRate

    inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: true)!
    let fileFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.fileRate, channels: 1, interleaved: true)!
    guard let converter = AVAudioConverter(from: inputFormat, to: fileFormat) else {
      Self.destroy(aggregate: aggregate, tap: tap)
      throw CaptureError("Kon niet omzetten van \(Int(sampleRate)) Hz naar 16 kHz.")
    }
    self.converter = converter
    do {
      file = try AVAudioFile(forWriting: url, settings: fileFormat.settings,
                             commonFormat: .pcmFormatInt16, interleaved: true)
    } catch {
      Self.destroy(aggregate: aggregate, tap: tap)
      throw CaptureError("Kon \(url.lastPathComponent) niet aanmaken: \(error.localizedDescription)")
    }

    var created: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&created, aggregate, nil) { [weak self] _, input, _, _, _ in
      self?.process(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
    }
    guard status == noErr, let created, AudioDeviceStart(aggregate, created) == noErr else {
      if let created { AudioDeviceDestroyIOProcID(aggregate, created) }
      Self.destroy(aggregate: aggregate, tap: tap)
      throw CaptureError("Kon de opname niet starten. Controleer de microfoontoegang van Pensieve.")
    }
    procID = created
  }

  private static func destroy(aggregate: AudioObjectID, tap: AudioObjectID) {
    AudioHardwareDestroyAggregateDevice(aggregate)
    AudioHardwareDestroyProcessTap(tap)
  }

  // Runs on the HAL's IO thread. Mixes the frame to mono here and hands the
  // conversion and disk write to a serial queue.
  private func process(_ buffers: UnsafeMutableAudioBufferListPointer) {
    var frames = 0
    for buffer in buffers where buffer.mNumberChannels > 0 {
      frames = max(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / Int(buffer.mNumberChannels))
    }
    guard frames > 0 else { return }

    var mic = [Float](repeating: 0, count: frames)
    var call = [Float](repeating: 0, count: frames)
    var micChannels = 0
    var callChannels = 0
    for (index, buffer) in buffers.enumerated() {
      guard let raw = buffer.mData, buffer.mNumberChannels > 0 else { continue }
      let channels = Int(buffer.mNumberChannels)
      let samples = raw.assumingMemoryBound(to: Float.self)
      let available = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
      let isMic = index < micBuffers
      for frame in 0..<available {
        var sum: Float = 0
        for channel in 0..<channels { sum += samples[frame * channels + channel] }
        if isMic { mic[frame] += sum } else { call[frame] += sum }
      }
      if isMic { micChannels += channels } else { callChannels += channels }
    }

    var micPeak: Float = 0
    var callPeak: Float = 0
    var mixed = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
      let m = micChannels > 0 ? mic[frame] / Float(micChannels) : 0
      let c = callChannels > 0 ? call[frame] / Float(callChannels) : 0
      micPeak = max(micPeak, abs(m))
      callPeak = max(callPeak, abs(c))
      mixed[frame] = max(-1, min(1, m + c))
    }

    lock.lock()
    self.micPeak = micPeak
    self.callPeak = callPeak
    micSawSignal = micSawSignal || micPeak > 0
    debugPeaks = (max(debugPeaks.mic, micPeak), max(debugPeaks.call, callPeak))
    callSawSignal = callSawSignal || callPeak > 0
    lastBuffer = Date()
    lock.unlock()

    writer.async { [self] in write(mixed) }
  }

  private func write(_ mono: [Float]) {
    guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
    input.frameLength = AVAudioFrameCount(mono.count)
    mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }

    let capacity = AVAudioFrameCount(Double(mono.count) * Self.fileRate / sampleRate) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
    var handed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if handed { status.pointee = .noDataNow; return nil }
      handed = true
      status.pointee = .haveData
      return input
    }
    guard error == nil, output.frameLength > 0 else { return }
    try? file.write(from: output)
    framesWritten += AVAudioFramePosition(output.frameLength)
  }

  public var levels: Levels {
    lock.lock(); defer { lock.unlock() }
    let stale = Date().timeIntervalSince(lastBuffer) > 1
    let db = { (peak: Float) -> Double in peak > 0 ? Double(20 * log10(peak)) : -120 }
    let listening = Date().timeIntervalSince(started) > Self.silenceGrace
    return Levels(mic: stale ? -120 : db(micPeak),
                  call: stale ? -120 : db(callPeak),
                  micDead: listening && !micSawSignal,
                  callSilent: listening && !callSawSignal)
  }

  public var elapsed: TimeInterval { Date().timeIntervalSince(started) }

  // Finalising the WAV header is what makes the file playable, so the file is
  // closed only after the last buffer has been drained through the writer.
  public func stop() {
    if let procID {
      AudioDeviceStop(aggregateID, procID)
      AudioDeviceDestroyIOProcID(aggregateID, procID)
      self.procID = nil
    }
    Self.destroy(aggregate: aggregateID, tap: tapID)
    writer.sync {}
  }

  deinit { if procID != nil { stop() } }
}
