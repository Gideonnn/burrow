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

    /// Moves the window back onto its screen when it appears, after a sheet or
    /// alert closes and when the screens change.
    public func keepsWindowOnScreen() -> some View {
        background(WindowKeeper())
    }
}

private struct WindowKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> KeeperView { KeeperView() }
    func updateNSView(_ view: KeeperView, context: Context) {}

    final class KeeperView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didEndSheetNotification, NSWindow.didChangeScreenNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                        // AppKit may still move the window right after the sheet ends.
                        let window = note.object as? NSWindow
                        MainActor.assumeIsolated { DispatchQueue.main.async { window.map(Self.fit) } }
                    })
            }
            DispatchQueue.main.async { [weak window] in window.map(Self.fit) }
        }

        static func fit(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
            let fitted = WindowFrame.fitted(window.frame, in: screen.visibleFrame)
            if fitted != window.frame { window.setFrame(fitted, display: true, animate: true) }
        }
    }
}
