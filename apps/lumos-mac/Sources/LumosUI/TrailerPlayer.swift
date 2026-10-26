import AVKit
import LumosCore
import SwiftUI
import WebKit

/// The compact player in the inspector. It is only made after a click and
/// torn down when it leaves the screen, which stops the sound.
public struct TrailerPlayerView: View {
    @Environment(LumosModel.self) private var model
    let playback: TrailerPlayback
    let origin: URL?

    public init(playback: TrailerPlayback, origin: URL?) {
        self.playback = playback
        self.origin = origin
    }

    public var body: some View {
        let report: @MainActor (TrailerPlayback.Status) -> Void = { [model, ref = playback.ref] status in
            model.playerReported(status, for: ref)
        }
        switch playback.trailer {
        case let .youtube(key, _, _, _, _):
            YouTubePlayer(key: key, origin: origin, report: report)
        case let .direct(url, _, _, _, _, _):
            if let url = URL(string: url) { DirectPlayer(url: url, report: report) }
        }
    }
}

/// The YouTube IFrame player in a small web view, only for the trailer area.
/// YouTube refuses embeds without an origin, so the page gets the Burrow
/// server's address as its base. Its state events, not the page load, say
/// whether it plays.
struct YouTubePlayer: NSViewRepresentable {
    let key: String
    let origin: URL?
    let report: @MainActor (TrailerPlayback.Status) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(report: report) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The click on Lumos's own play button is the person's request.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "lumos")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.page(key: key, origin: origin), baseURL: origin)
        context.coordinator.startTimeout()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.timeout?.cancel()
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "lumos")
    }

    static func page(key: String, origin: URL?) -> String {
        let originText = origin.map { "\($0.scheme ?? "https")://\($0.host() ?? "")\($0.port.map { ":\($0)" } ?? "")" } ?? ""
        let safeKey = key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body><div id="player"></div>
        <script>
        function send(m){window.webkit.messageHandlers.lumos.postMessage(m)}
        window.onerror=function(m){send({event:'error',code:String(m)})};
        function onYouTubeIframeAPIReady(){
          new YT.Player('player',{videoId:'\(safeKey)',host:'https://www.youtube-nocookie.com',
            playerVars:{autoplay:1,playsinline:1,rel:0,origin:'\(originText)'},
            events:{
              onReady:function(e){send({event:'ready'});e.target.playVideo()},
              onStateChange:function(e){send({event:'state',state:e.data})},
              onError:function(e){send({event:'error',code:String(e.data)})}
            }});
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="send({event:'error',code:'api'})"></script>
        </body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let report: @MainActor (TrailerPlayback.Status) -> Void
        var timeout: Task<Void, Never>?
        private var answered = false

        init(report: @escaping @MainActor (TrailerPlayback.Status) -> Void) {
            self.report = report
        }

        func startTimeout() {
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, !Task.isCancelled, !self.answered else { return }
                self.report(.failed("Geen antwoord van de YouTube-speler. Offline, geblokkeerd of niet insluitbaar."))
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
            answered = true
            switch event {
            case "ready": report(.loaded)
            case "state":
                // -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
                switch body["state"] as? Int {
                case 1: report(.playing)
                case 2: report(.paused)
                case 0: report(.ended)
                default: break
                }
            default:
                let code = body["code"] as? String ?? ""
                report(.failed(code == "101" || code == "150" || code == "153"
                    ? "De maker staat insluiten niet toe (YouTube-fout \(code)). Gebruik Groot beeld bij bron."
                    : "De YouTube-speler meldde een fout (\(code))."))
            }
        }
    }
}

/// A direct stream (an MP4) in the Mac's own player. Not SwiftUI's
/// VideoPlayer: it crashes in a package executable (see the Pensieve diary).
struct DirectPlayer: NSViewRepresentable {
    let url: URL
    let report: @MainActor (TrailerPlayback.Status) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(report: report) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        let player = AVPlayer(url: url)
        view.player = player
        context.coordinator.observe(player)
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
    }

    @MainActor
    final class Coordinator {
        let report: @MainActor (TrailerPlayback.Status) -> Void
        private var observations: [NSKeyValueObservation] = []
        private var ended: NSObjectProtocol?

        init(report: @escaping @MainActor (TrailerPlayback.Status) -> Void) {
            self.report = report
        }

        func observe(_ player: AVPlayer) {
            let report = report
            observations.append(player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                let status = player.timeControlStatus
                Task { @MainActor in
                    switch status {
                    case .playing: report(.playing)
                    case .paused: if player.currentItem?.status == .readyToPlay { report(.paused) }
                    default: break
                    }
                }
            })
            if let item = player.currentItem {
                observations.append(item.observe(\.status, options: [.new]) { item, _ in
                    let failed = item.status == .failed
                    let reason = item.error?.localizedDescription
                    Task { @MainActor in
                        if failed { report(.failed("De stream is niet bereikbaar\(reason.map { ": \($0)" } ?? ".")")) }
                    }
                })
                ended = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
                ) { _ in Task { @MainActor in report(.ended) } }
            }
        }

        func stop() {
            observations.forEach { $0.invalidate() }
            observations = []
            if let ended { NotificationCenter.default.removeObserver(ended) }
        }
    }
}
