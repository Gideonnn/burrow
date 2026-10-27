import AppKit
import os
import SwiftUI

/// When a pull past the top of a list starts a refresh: once the pull passed the
/// threshold and the fingers leave the trackpad, like Mail on the iPhone. Pulling
/// back below the threshold before letting go cancels it.
public struct PullToRefreshState: Equatable, Sendable {
    public static let threshold: CGFloat = 50

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
    /// Pull-to-refresh for a list on the Mac. AppKit has no refresh control,
    /// `.refreshable` shows nothing there, and SwiftUI reports no scroll phase for
    /// a `List` on the Mac, so this reads the fingers from the scroll events and
    /// the elastic overscroll from the list's own NSScrollView.
    public func pullToRefresh(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(PullToRefresh(action: action))
    }
}

private struct PullToRefresh: ViewModifier {
    let action: @MainActor () async -> Void
    @State private var tracker = PullTracker()
    private static let gap: CGFloat = 64

    func body(content: Content) -> some View {
        content
            // Like Mail: the system spinner in a gap of its own above the list,
            // which stays pushed down while refreshing.
            .safeAreaInset(edge: .top, spacing: 0) {
                if tracker.state.refreshing {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Self.gap)
                        .transition(.opacity)
                }
            }
            .background(ScrollViewLink(tracker: tracker, action: action))
            .overlay(alignment: .top) {
                if tracker.state.isPulling {
                    ProgressView()
                        .opacity(tracker.state.progress)
                        .frame(maxWidth: .infinity)
                        .frame(height: tracker.state.pull)
                        .clipped()
                        .padding(.top, tracker.top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(.default, value: tracker.state.refreshing)
    }
}

@MainActor @Observable
final class PullTracker {
    private(set) var state = PullToRefreshState()
    private(set) var top: CGFloat = 0
    @ObservationIgnored var action: @MainActor () async -> Void = {}
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let log = Logger(subsystem: "app.burrow.ui", category: "pull-to-refresh")

    func attach(_ scrollView: NSScrollView) {
        guard scrollView !== self.scrollView else { return }
        detach()
        self.scrollView = scrollView
        // A short list bounces too, so there is always something to pull.
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scrolled() } }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        Self.log.notice(
            "attached to \(String(describing: type(of: scrollView)), privacy: .public), top inset \(scrollView.contentInsets.top, privacy: .public), at rest \(scrollView.contentView.bounds.minY, privacy: .public)"
        )
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        monitor = nil
        observer = nil
        scrollView = nil
    }

    private func scrolled() {
        guard let scrollView else { return }
        top = scrollView.contentInsets.top
        state.scrolled(pull: -(scrollView.contentView.bounds.minY + scrollView.contentInsets.top))
    }

    // Momentum events carry no phase, so only the fingers count.
    private func handle(_ event: NSEvent) {
        guard let scrollView, event.window === scrollView.window else { return }
        if event.phase.contains(.began) {
            let inside = scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
            if inside { _ = state.phase(interacting: true) }
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled), state.interacting {
            let pull = state.pull
            let start = state.phase(interacting: false)
            Self.log.notice("released at \(pull, privacy: .public) pt, top inset \(self.top, privacy: .public), refresh \(start, privacy: .public)")
            guard start else { return }
            Task {
                await action()
                withAnimation { state.finished() }
            }
        }
    }
}

/// Behind the list, to find the NSScrollView SwiftUI made for it: the one that
/// covers the same part of the window.
private struct ScrollViewLink: NSViewRepresentable {
    let tracker: PullTracker
    let action: @MainActor () async -> Void

    func makeNSView(context: Context) -> LinkView {
        let view = LinkView()
        view.tracker = tracker
        return view
    }

    func updateNSView(_ view: LinkView, context: Context) {
        tracker.action = action
        view.link()
    }

    static func dismantleNSView(_ view: LinkView, coordinator: ()) {
        view.tracker?.detach()
    }

    final class LinkView: NSView {
        weak var tracker: PullTracker?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link()
        }

        override func layout() {
            super.layout()
            link()
        }

        // The list's scroll view may appear a moment after this view.
        func link() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, let root = window.contentView else { return }
                let mine = convert(bounds, to: nil)
                let best = Self.scrollViews(in: root)
                    .map { ($0, $0.convert($0.bounds, to: nil).intersection(mine)) }
                    .filter { !$0.1.isNull && $0.1.width * $0.1.height > mine.width * mine.height / 2 }
                    .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
                if let scrollView = best?.0 { tracker?.attach(scrollView) }
            }
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            if let scrollView = view as? NSScrollView { return [scrollView] }
            return view.subviews.flatMap(scrollViews)
        }
    }
}
