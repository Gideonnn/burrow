import AppKit
import ApplicationServices
import Foundation

/// What pasting needs from the system; the real one is `SystemPasteTarget`.
@MainActor
public protocol PasteTarget {
    /// Whether Pensieve may send keystrokes (Accessibility).
    var trusted: Bool { get }
    /// The app that has the cursor, to say where the text went.
    var frontmostApp: String? { get }
    var changeCount: Int { get }
    func clipboard() -> String?
    func setClipboard(_ text: String?)
    func pressPaste() -> Bool
}

public enum PasteOutcome: Equatable, Sendable {
    /// Pasted at the cursor, in this app.
    case pasted(app: String?)
    /// Without Accessibility, the text waits on the clipboard for ⌘V.
    case onClipboard
}

/// Puts a dictation where the cursor is: on the clipboard and ⌘V, then the
/// clipboard goes back to what it held. Without the Accessibility permission
/// the text stays on the clipboard. Typing into the focused field through the
/// Accessibility API was rejected: many apps (browsers, Electron) accept the
/// call and show nothing.
@MainActor
public struct Paster {
    let target: PasteTarget
    let restoreAfter: Duration

    public init(target: PasteTarget, restoreAfter: Duration = .milliseconds(400)) {
        self.target = target
        self.restoreAfter = restoreAfter
    }

    public func paste(_ text: String) async -> PasteOutcome {
        guard target.trusted else {
            target.setClipboard(text)
            return .onClipboard
        }
        let previous = target.clipboard()
        target.setClipboard(text)
        let ours = target.changeCount
        guard target.pressPaste() else { return .onClipboard }
        try? await Task.sleep(for: restoreAfter)
        // Someone copied something meanwhile: leave theirs.
        if target.changeCount == ours { target.setClipboard(previous) }
        return .pasted(app: target.frontmostApp)
    }
}

@MainActor
public final class SystemPasteTarget: PasteTarget {
    public init() {}

    public var trusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt once.
    public func askForPermission() {
        // The constant's value; the global itself is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public var frontmostApp: String? { NSWorkspace.shared.frontmostApplication?.localizedName }
    public var changeCount: Int { NSPasteboard.general.changeCount }

    public func clipboard() -> String? { NSPasteboard.general.string(forType: .string) }

    public func setClipboard(_ text: String?) {
        NSPasteboard.general.clearContents()
        if let text { NSPasteboard.general.setString(text, forType: .string) }
    }

    public func pressPaste() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
