import Foundation

/// The trailer in the inspector. It exists only after a click and goes the
/// moment the inspector closes or shows another title. "Playing" is only
/// ever what the player itself reported, never that a page loaded.
public struct TrailerPlayback: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case loading
        /// The YouTube player answered, but has not said it plays.
        case loaded
        case playing
        case paused
        case ended
        case failed(String)
    }

    public var ref: TitleRef
    public var trailer: Trailer
    public var status: Status = .loading

    public init(ref: TitleRef, trailer: Trailer) {
        self.ref = ref
        self.trailer = trailer
    }

    public var isYouTube: Bool {
        if case .youtube = trailer { return true }
        return false
    }

    public var statusText: String {
        switch status {
        case .loading: isYouTube ? "Verbinden met youtube-nocookie.com…" : "Stream laden…"
        case .loaded: "Speler geladen; nog niet gemeld dat hij speelt"
        case .playing: isYouTube ? "Speelt af, gemeld door de YouTube-speler" : "Speelt af, gemeld door de videospeler"
        case .paused: "Gepauzeerd"
        case .ended: "Afgelopen"
        case .failed(let reason): reason
        }
    }
}
