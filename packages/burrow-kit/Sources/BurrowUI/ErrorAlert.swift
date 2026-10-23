import AppKit
import BurrowKit
import SwiftUI

extension View {
    /// "Er ging iets mis" with a short text: a long one made the alert taller
    /// than the screen and pushed the window off it.
    public func errorAlert(_ error: Binding<String?>) -> some View {
        alert(
            "Er ging iets mis",
            isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }),
            actions: { Button("OK") { error.wrappedValue = nil } },
            message: { Text(ErrorText.short(error.wrappedValue ?? "")) })
    }

    /// Moves the window back onto its screen when it appears and after a sheet
    /// or alert closes.
    public func keepsWindowOnScreen() -> some View {
        background(WindowKeeper())
    }
}

private struct WindowKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> KeeperView { KeeperView() }
    func updateNSView(_ view: KeeperView, context: Context) {}

    final class KeeperView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification, object: window, queue: .main
            ) { note in
                // AppKit may still move the window right after the sheet ends.
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { DispatchQueue.main.async { window.map(Self.fit) } }
            }
            DispatchQueue.main.async { [weak window] in window.map(Self.fit) }
        }

        // No didChangeScreen observer and no animation: moving the window to another
        // Space in Mission Control reports a passing screen change, and an animated
        // setFrame then hid the window. Only a settled window on this Space is fitted.
        static func fit(_ window: NSWindow) {
            guard window.isVisible, window.isOnActiveSpace, NSEvent.pressedMouseButtons == 0,
                !window.styleMask.contains(.fullScreen), let screen = window.screen
            else { return }
            let fitted = WindowFrame.fitted(window.frame, in: screen.visibleFrame)
            if fitted != window.frame { window.setFrame(fitted, display: true) }
        }
    }
}
