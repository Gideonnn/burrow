import Foundation
import Observation
import PensieveCapture
import PensieveCore

/// One recording at a time: starts the capture into the outbox, shows the
/// meters while it runs, and hands the file to the model when it stops.
@MainActor
@Observable
final class RecorderController {
    private(set) var recorder: Recorder?
    private(set) var title = ""
    private(set) var startedAt: Date?
    private(set) var levels = Levels()
    private(set) var elapsed: TimeInterval = 0
    private(set) var microphones: [Device] = []
    var microphone: Device?
    var error: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let model: PensieveModel

    init(model: PensieveModel) {
        self.model = model
        refreshMicrophones()
    }

    var isRecording: Bool { recorder != nil }

    func refreshMicrophones() {
        microphones = PensieveCapture.microphones()
        if microphone == nil || !microphones.contains(where: { $0.uid == microphone?.uid }) {
            microphone = preferredMicrophone()
        }
    }

    func start(title: String) async {
        guard recorder == nil else { return }
        guard let microphone = microphone ?? preferredMicrophone() else {
            error = "Er is geen microfoon gevonden."
            return
        }
        let granted = await withCheckedContinuation { continuation in
            requestMicrophoneAccess { continuation.resume(returning: $0) }
        }
        guard granted else {
            error = "Pensieve mag de microfoon niet gebruiken. Zet het aan in Systeeminstellingen › Privacy en beveiliging › Microfoon."
            return
        }
        do {
            let file = try model.outbox.newAudioFile()
            recorder = try Recorder(microphone: microphone, url: file)
            self.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Opname" : title
            startedAt = Date()
            model.recordingTitle = self.title
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let recorder = self.recorder else { return }
                    self.levels = recorder.levels
                    self.elapsed = recorder.elapsed
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rename(_ title: String) {
        self.title = title
        model.recordingTitle = title
    }

    /// Stops, closes the WAV and sends it on its way.
    func stop() async {
        guard let recorder, let startedAt else { return }
        ticker?.cancel()
        recorder.stop()
        self.recorder = nil
        model.recordingTitle = nil
        levels = Levels()
        await model.finished(audio: recorder.url, title: title, startedAt: startedAt)
    }
}

/// "1:02:03" or "42:17".
func clock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.down))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
