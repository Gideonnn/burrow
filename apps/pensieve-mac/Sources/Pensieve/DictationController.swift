import AVFoundation
import Foundation
import Observation
import PensieveCapture
import PensieveCore

/// Hold ⌥ Spatie anywhere, talk, let go: the text is pasted where the cursor
/// is and kept as a dictation in Pensieve. The HUD that shows `state` comes
/// with the UI work, which also decides when `enable()` is called.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case listening(since: Date)
        case transcribing
        case pasted(PasteOutcome)
        case failed(String)
    }

    private(set) var state: State = .idle
    var labels: [String] = []
    @ObservationIgnored private var hotKey: HoldHotKey?
    @ObservationIgnored private var recorder: DictationRecorder?
    @ObservationIgnored private let model: PensieveModel
    @ObservationIgnored private let paster: Paster
    /// A tap shorter than this was not meant as a dictation.
    private let shortest: TimeInterval = 0.4

    init(model: PensieveModel, paster: Paster = Paster(target: SystemPasteTarget())) {
        self.model = model
        self.paster = paster
    }

    var isEnabled: Bool { hotKey != nil }

    func enable() throws {
        guard hotKey == nil else { return }
        hotKey = try HoldHotKey(
            onPress: { [weak self] in MainActor.assumeIsolated { self?.begin() } },
            onRelease: { [weak self] in
                Task { @MainActor in await self?.end() }
            })
    }

    func disable() {
        hotKey?.invalidate()
        hotKey = nil
    }

    func begin() {
        guard recorder == nil, model.connection != nil else { return }
        guard AVCaptureAuthorized.microphone else {
            requestMicrophoneAccess { _ in }
            state = .failed("Pensieve mag de microfoon niet gebruiken.")
            return
        }
        do {
            recorder = try DictationRecorder(url: try model.outbox.newAudioFile(extension: "m4a"))
            state = .listening(since: Date())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func end() async {
        guard let recorder else { return }
        self.recorder = nil
        let seconds = recorder.stop()
        guard seconds >= shortest else {
            try? FileManager.default.removeItem(at: recorder.url)
            state = .idle
            return
        }
        state = .transcribing
        do {
            let detail = try await model.dictate(audio: recorder.url, startedAt: recorder.started, labels: labels)
            state = .pasted(await paster.paste(detail.transcript ?? ""))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private enum AVCaptureAuthorized {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
}
