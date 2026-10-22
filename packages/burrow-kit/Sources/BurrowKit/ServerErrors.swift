import CoreGraphics
import Foundation
import Observation

extension APIError {
    /// Gateways (Cloudflare, cloudflared) answer these while the server or the
    /// tunnel restarts; our own server always sends a JSON error with them.
    static let gatewayStatuses = Set([502, 503, 504] + Array(520...530))

    static let connectionErrors: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
        .notConnectedToInternet, .timedOut, .resourceUnavailable, .dataNotAllowed, .internationalRoamingOff,
    ]

    /// The server cannot be reached right now, but will be soon: retry quietly.
    public static func isTransient(_ error: any Error) -> Bool {
        if case .unavailable = error as? APIError { return true }
        if let error = error as? URLError { return connectionErrors.contains(error.code) }
        return false
    }

    /// A short text for an alert; never a page of HTML.
    public static func describe(_ error: any Error) -> String {
        if isTransient(error) { return APIError.unavailable(status: nil).errorDescription ?? "" }
        return ErrorText.short(error.localizedDescription)
    }
}

public enum ErrorText {
    /// At most a few lines, so an alert never grows taller than the screen.
    public static func short(_ text: String, lines: Int = 4, length: Int = 300) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept = trimmed.split(separator: "\n", omittingEmptySubsequences: false).prefix(lines).joined(separator: "\n")
        if kept.count > length { kept = String(kept.prefix(length - 1)) }
        return kept == trimmed ? trimmed : kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Whether the server answers, for the indicator in the sidebar. After a lost
/// connection it asks again with growing pauses until the server is back.
@MainActor @Observable
public final class ServerReachability {
    public private(set) var isReachable = true
    @ObservationIgnored public var probe: @MainActor () async -> Bool = { true }
    @ObservationIgnored public var onRegained: @MainActor () async -> Void = {}
    @ObservationIgnored private let delays: [Duration]
    @ObservationIgnored private var retrying: Task<Void, Never>?

    public init(delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(30)]) {
        self.delays = delays
    }

    public func lost() {
        isReachable = false
        guard retrying == nil else { return }
        retrying = Task { [weak self, delays] in
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: delays[min(attempt, delays.count - 1)])
                attempt += 1
                guard let self, !Task.isCancelled else { return }
                if await self.probe() {
                    // Not cancelled: the reloads in onRegained run in this task.
                    self.retrying = nil
                    await self.back()
                    return
                }
            }
        }
    }

    /// The server answered elsewhere, e.g. the live stream connected again.
    public func answered() async {
        retrying?.cancel()
        retrying = nil
        await back()
    }

    private func back() async {
        guard !isReachable else { return }
        isReachable = true
        await onRegained()
    }
}

public enum WindowFrame {
    /// The frame moved and, when needed, shrunk to lie within the visible screen.
    public static func fitted(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var fitted = frame
        fitted.size.width = min(frame.width, visible.width)
        fitted.size.height = min(frame.height, visible.height)
        fitted.origin.x = min(max(frame.minX, visible.minX), visible.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
        return fitted
    }
}
