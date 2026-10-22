import AVFoundation
import Foundation

// Dictation: the microphone only, straight to AAC in an m4a, small enough to
// upload in a moment. Uses the system's default input, as the hot key can
// come at any time.

public final class DictationRecorder {
  public let url: URL
  private let recorder: AVAudioRecorder
  public let started = Date()

  public init(url: URL) throws {
    self.url = url
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ]
    do {
      recorder = try AVAudioRecorder(url: url, settings: settings)
    } catch {
      throw CaptureError("Kon niet beginnen met dicteren: \(error.localizedDescription)")
    }
    recorder.isMeteringEnabled = true
    guard recorder.record() else { throw CaptureError("Kon niet beginnen met dicteren. Controleer de microfoontoegang van Pensieve.") }
  }

  /// Decibels, for the listening dot.
  public var level: Double {
    recorder.updateMeters()
    return Double(recorder.averagePower(forChannel: 0))
  }

  public var elapsed: TimeInterval { Date().timeIntervalSince(started) }

  /// Stops and closes the file; returns how long it ran.
  @discardableResult
  public func stop() -> TimeInterval {
    let seconds = recorder.currentTime
    recorder.stop()
    return seconds
  }
}
