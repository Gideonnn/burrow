import AVFoundation
import Foundation
import Observation
import PensieveCapture
import PensieveCore
import PensieveMedia

/// One recording at a time, of any kind but dictation: starts the capture,
/// keeps the marks and the meters while it runs, and hands the file to the
/// model when it stops. Starting is always the person's.
@MainActor
@Observable
final class RecorderController {
    private enum Active {
        case call(Recorder)
        case video(VideoCapture)
        // A ScreenCapture, which needs macOS 15.
        case screen(AnyObject)
    }

    private var active: Active?
    private(set) var kind: RecordingKind = .call
    private(set) var title = ""
    var labels: [String] = []
    private(set) var marks = MarkList()
    private(set) var startedAt: Date?
    private(set) var levels = Levels()
    private(set) var elapsed: TimeInterval = 0
    private(set) var microphones: [Device] = []
    var microphone: Device? {
        didSet { UserDefaults.standard.set(microphone?.uid, forKey: MacSettings.microphone) }
    }
    /// Nil is the system's default camera.
    var camera: String? = UserDefaults.standard.string(forKey: MacSettings.camera) {
        didSet { UserDefaults.standard.set(camera, forKey: MacSettings.camera) }
    }
    /// Screen recordings take the microphone only when asked.
    var screenWithMicrophone = UserDefaults.standard.bool(forKey: MacSettings.screenWithMicrophone) {
        didSet { UserDefaults.standard.set(screenWithMicrophone, forKey: MacSettings.screenWithMicrophone) }
    }
    var format = MacSettings.recordingFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: MacSettings.format) }
    }
    var error: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let model: PensieveModel

    init(model: PensieveModel) {
        self.model = model
        refreshMicrophones()
    }

    var isRecording: Bool { active != nil }

    /// The camera, for the preview on the recording stage.
    var cameraSession: AVCaptureSession? {
        if case .video(let capture) = active { return capture.session }
        return nil
    }

    func refreshMicrophones() {
        microphones = PensieveCapture.microphones()
        if microphone == nil || !microphones.contains(where: { $0.uid == microphone?.uid }) {
            let saved = UserDefaults.standard.string(forKey: MacSettings.microphone)
            microphone = microphones.first { $0.uid == saved } ?? preferredMicrophone()
        }
    }

    /// A call, as before: title from the sheet.
    func start(title: String) async {
        await start(.call, title: title, labels: labels)
    }

    /// One click: title and labels default from the previous recording of the kind.
    func start(_ kind: RecordingKind, title: String? = nil, labels: [String]? = nil) async {
        guard active == nil, kind != .dictation else { return }
        let suggestion = model.suggestion(for: kind)
        let name = (title ?? suggestion.title).trimmingCharacters(in: .whitespaces)
        guard await permitted(kind) else { return }
        do {
            switch kind {
            case .call:
                guard let microphone = microphone ?? preferredMicrophone() else {
                    error = "Er is geen microfoon gevonden."
                    return
                }
                active = .call(try Recorder(microphone: microphone, url: try model.outbox.newAudioFile()))
            case .video:
                let capture = try VideoCapture(camera: camera, microphone: microphone?.uid, url: try model.shelf.newOriginal())
                capture.start()
                active = .video(capture)
            case .screen:
                guard #available(macOS 15.0, *) else {
                    error = "Scherm opnemen vraagt macOS 15 of nieuwer."
                    return
                }
                let capture = ScreenCapture(url: try model.shelf.newOriginal())
                try await capture.start(microphone: screenWithMicrophone ? microphone?.uid : nil)
                active = .screen(capture)
            case .dictation:
                return
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        self.kind = kind
        self.title = name.isEmpty ? RecordingDefaults.name(of: kind) : name
        self.labels = labels ?? suggestion.labels
        marks = MarkList()
        startedAt = Date()
        model.recordingTitle = self.title
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active != nil else { return }
                self.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func permitted(_ kind: RecordingKind) async -> Bool {
        let microphone = await withCheckedContinuation { continuation in
            requestMicrophoneAccess { continuation.resume(returning: $0) }
        }
        guard microphone || (kind == .screen && !screenWithMicrophone) else {
            error = "Pensieve mag de microfoon niet gebruiken. Zet het aan in Systeeminstellingen › Privacy en beveiliging › Microfoon."
            return false
        }
        if kind == .video {
            let camera = await withCheckedContinuation { continuation in
                requestCameraAccess { continuation.resume(returning: $0) }
            }
            guard camera else {
                error = "Pensieve mag de camera niet gebruiken. Zet het aan in Systeeminstellingen › Privacy en beveiliging › Camera."
                return false
            }
        }
        return true
    }

    private func tick() {
        switch active {
        case .call(let recorder):
            levels = recorder.levels
            elapsed = recorder.elapsed
        case .video(let capture):
            elapsed = capture.elapsed
        case .screen:
            elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        case nil:
            break
        }
    }

    /// "Markeer moment": now, with an optional note.
    @discardableResult
    func mark(note: String? = nil) -> Int? {
        guard isRecording else { return nil }
        tick()
        return marks.mark(at: elapsed, note: note)
    }

    func setNote(_ note: String?, ofMark index: Int) {
        marks.setNote(note, at: index)
    }

    func rename(_ title: String) {
        self.title = title
        model.recordingTitle = title
    }

    /// Stops, closes the file and sends it on its way.
    func stop() async {
        guard let active, let startedAt else { return }
        ticker?.cancel()
        self.active = nil
        model.recordingTitle = nil
        levels = Levels()
        let marks = marks.marks
        switch active {
        case .call(let recorder):
            recorder.stop()
            await model.finished(
                audio: recorder.url, kind: .call, title: title, startedAt: startedAt, marks: marks, labels: labels,
                transcribe: MacSettings.transcribes(.call))
        case .video(let capture):
            await finishVideo(startedAt: startedAt, marks: marks) { try await capture.stop() }
        case .screen(let capture):
            if #available(macOS 15.0, *), let capture = capture as? ScreenCapture {
                await finishVideo(startedAt: startedAt, marks: marks) { try await capture.stop() }
            }
        }
    }

    private func finishVideo(startedAt: Date, marks: [Mark], _ stop: () async throws -> URL) async {
        do {
            let original = try await stop()
            await model.finishedVideo(
                original: original, kind: kind, title: title, startedAt: startedAt, marks: marks, labels: labels, format: format,
                transcribe: MacSettings.transcribes(kind))
        } catch {
            self.error = "De opname kon niet worden afgesloten: \(error.localizedDescription)"
        }
    }
}

/// "1:02:03" or "42:17".
func clock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.down))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
