import AVFoundation
import Foundation

// Webcam plus microphone, for interviews: AVCaptureSession into a movie file.
// The raw file is large; the app compresses it to the shareable MP4 after
// Stop, on the shelf.

public struct Camera: Hashable, Sendable {
  public let uid: String
  public let name: String
}

public func cameras() -> [Camera] {
  AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
  ).devices.map { Camera(uid: $0.uniqueID, name: $0.localizedName) }
}

public func requestCameraAccess(_ done: @escaping (Bool) -> Void) {
  switch AVCaptureDevice.authorizationStatus(for: .video) {
  case .authorized: done(true)
  case .notDetermined:
    AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { done(granted) } }
  default: done(false)
  }
}

public final class VideoCapture: NSObject, AVCaptureFileOutputRecordingDelegate {
  public let url: URL
  /// For a preview layer in the recording stage.
  public let session = AVCaptureSession()
  private let output = AVCaptureMovieFileOutput()
  private let queue = DispatchQueue(label: "app.burrow.pensieve.video")
  private var finished: CheckedContinuation<URL, Error>?
  private var failure: Error?
  public private(set) var started: Date?

  /// `camera` and `microphone` are unique ids; nil takes the system default.
  /// A CoreAudio microphone uid is also its AVCaptureDevice id.
  public init(camera: String?, microphone: String?, url: URL) throws {
    self.url = url
    super.init()
    guard let video = camera.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
      throw CaptureError("Er is geen camera gevonden.")
    }
    guard let audio = microphone.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
      throw CaptureError("Er is geen microfoon gevonden.")
    }
    session.beginConfiguration()
    session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
    for device in [video, audio] {
      let input: AVCaptureDeviceInput
      do { input = try AVCaptureDeviceInput(device: device) } catch {
        session.commitConfiguration()
        throw CaptureError("Kon \(device.localizedName) niet gebruiken: \(error.localizedDescription)")
      }
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        throw CaptureError("Kon \(device.localizedName) niet gebruiken.")
      }
      session.addInput(input)
    }
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw CaptureError("Kon geen videobestand maken.")
    }
    session.addOutput(output)
    session.commitConfiguration()
  }

  public func start() {
    queue.sync {
      session.startRunning()
      output.startRecording(to: url, recordingDelegate: self)
    }
    started = Date()
  }

  /// Seconds recorded so far, for marks.
  public var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }

  /// Stops and waits until the file is complete.
  public func stop() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard output.isRecording else {
          session.stopRunning()
          if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: url) }
          return
        }
        finished = continuation
        output.stopRecording()
      }
    }
  }

  public func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection],
    error: Error?
  ) {
    queue.async { [self] in
      session.stopRunning()
      // A stop reports an "error" that still leaves a complete file.
      let complete = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
      if complete {
        finished?.resume(returning: outputFileURL)
      } else {
        failure = error
        finished?.resume(throwing: error ?? CaptureError("De video-opname stopte onverwacht."))
      }
      finished = nil
    }
  }
}

// Its state is only touched on `queue`.
extension VideoCapture: @unchecked Sendable {}
