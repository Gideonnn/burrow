import Foundation
import PensieveCore
import PensieveMedia

/// Settings of Pensieve on this Mac; the server keeps the household's.
enum MacSettings {
    static let dictation = "pensieve.dictation"
    static let format = "pensieve.format"
    static let microphone = "pensieve.microphone"
    static let camera = "pensieve.camera"
    static let screenWithMicrophone = "pensieve.screenWithMicrophone"

    static func transcribeKey(_ kind: RecordingKind) -> String { "pensieve.transcribe.\(kind.rawValue)" }

    /// Whether a finished recording of this kind is transcribed right away;
    /// video and screen wait for the button unless switched on.
    static func transcribes(_ kind: RecordingKind) -> Bool {
        UserDefaults.standard.object(forKey: transcribeKey(kind)) as? Bool ?? kind.transcribesByDefault
    }

    static var dictationOn: Bool { UserDefaults.standard.object(forKey: dictation) as? Bool ?? true }

    static var recordingFormat: RecordingFormat {
        UserDefaults.standard.string(forKey: format).flatMap(RecordingFormat.init(rawValue:)) ?? .normal
    }
}
