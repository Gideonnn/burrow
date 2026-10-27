import SwiftUI

/// When a pull past the top of a list starts a refresh: once the pull passed the
/// threshold and the fingers leave the trackpad, like Mail on the iPhone. Pulling
/// back below the threshold before letting go cancels it.
public struct PullToRefreshState: Equatable, Sendable {
    public static let threshold: CGFloat = 64

    public private(set) var pull: CGFloat = 0
    public private(set) var interacting = false
    public private(set) var armed = false
    public private(set) var refreshing = false

    public init() {}

    public var progress: Double { Double(min(pull / Self.threshold, 1)) }
    public var isPulling: Bool { interacting && pull > 0 && !refreshing }

    public mutating func scrolled(pull: CGFloat) {
        self.pull = max(0, pull)
        if interacting, !refreshing { armed = self.pull >= Self.threshold }
    }

    /// Returns true when the refresh should start now.
    public mutating func phase(interacting: Bool) -> Bool {
        let released = self.interacting && !interacting
        self.interacting = interacting
        guard released else { return false }
        defer { armed = false }
        guard armed, !refreshing else { return false }
        refreshing = true
        return true
    }

    public mutating func finished() { refreshing = false }
}

extension View {
    /// Pull-to-refresh for a list on the Mac. AppKit has no refresh control and
    /// `.refreshable` shows nothing there, so this reads the elastic overscroll
    /// at the top (macOS 15 and later; earlier versions keep ⌘R only).
    public func pullToRefresh(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(PullToRefresh(action: action))
    }
}

private struct PullToRefresh: ViewModifier {
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(ScrollPull(action: action))
        } else {
            content
        }
    }
}

@available(macOS 15, *)
private struct ScrollPull: ViewModifier {
    let action: @MainActor () async -> Void
    @State private var state = PullToRefreshState()
    @State private var top: CGFloat = 0

    private struct Overscroll: Equatable {
        var pull: CGFloat
        var top: CGFloat
    }

    func body(content: Content) -> some View {
        content
            // While refreshing the spinner gets a row of its own, so the list
            // stays pushed down the way it does on the iPhone.
            .safeAreaInset(edge: .top, spacing: 0) {
                if state.refreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .transition(.opacity)
                }
            }
            .onScrollGeometryChange(for: Overscroll.self) { geometry in
                Overscroll(pull: -(geometry.contentOffset.y + geometry.contentInsets.top), top: geometry.contentInsets.top)
            } action: { _, new in
                top = new.top
                state.scrolled(pull: new.pull)
            }
            .onScrollPhaseChange { _, phase in
                guard state.phase(interacting: phase == .interacting) else { return }
                Task { @MainActor in
                    await action()
                    withAnimation { state.finished() }
                }
            }
            .overlay(alignment: .top) {
                if state.isPulling {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .padding(.top, top + max(0, state.pull - 20) / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(.default, value: state.refreshing)
    }
}
