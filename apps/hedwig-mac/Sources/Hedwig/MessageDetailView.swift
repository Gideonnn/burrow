import HedwigCore
import SwiftUI
import WebKit

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(remoteImagesKey) private var loadRemoteImages = false
    // The one message whose images the person chose to load.
    @State private var allowedMessageId: String?

    var body: some View {
        if let message = model.detail {
            VStack(alignment: .leading, spacing: 0) {
                MessageHeader(message: message)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                if model.showsOutingCard {
                    OutingCard()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                if let summary = model.insights?.summary {
                    Label(summary, systemImage: "sparkles")
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                Divider()
                if let html = message.bodyHtml {
                    RemoteImagesBar(html: html, messageId: message.id, allowed: $allowedMessageId, always: loadRemoteImages)
                    HTMLView(html: html, allowRemote: loadRemoteImages || allowedMessageId == message.id)
                } else {
                    ScrollView {
                        Text(message.bodyText ?? message.snippet)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { SuggestionBar() }
        } else {
            ContentUnavailableView("Geen bericht geselecteerd", systemImage: "envelope")
        }
    }
}

struct MessageHeader: View {
    @Environment(AppModel.self) private var model
    let message: MessageDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(name: message.from.display)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.from.display).font(.headline).lineLimit(1).layoutPriority(1)
                        if message.from.name != nil {
                            Text(message.from.email).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Text("Aan: \(Address.format(message.to))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !message.cc.isEmpty {
                        Text("Cc: \(Address.format(message.cc))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.subject).font(.title2.weight(.semibold)).textSelection(.enabled)
            if message.hasAttachments {
                Label("Bevat bijlagen; open ze voorlopig in de webmail", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Avatar: View {
    let name: String

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(initials.uppercased())
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(color))
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        return palette[abs(name.hashValue) % palette.count]
    }
}

let remoteImagesKey = "loadRemoteImages"

/// Remote images tell the sender when and where mail was opened, so they load
/// only when the person asks: for this message, or always (Instellingen).
struct RemoteImagesBar: View {
    let html: String
    let messageId: String
    @Binding var allowed: String?
    let always: Bool
    @AppStorage(remoteImagesKey) private var loadAlways = false

    var body: some View {
        if !always, allowed != messageId, HTMLView.hasRemoteContent(html) {
            HStack(spacing: 8) {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text("Externe afbeeldingen zijn niet geladen.").foregroundStyle(.secondary)
                Spacer()
                Button("Laad afbeeldingen") { allowed = messageId }
                Button("Altijd") { loadAlways = true }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
        }
    }
}

/// Renders mail HTML without JavaScript. Unless `allowRemote`, nothing loads
/// from the network, so trackers and remote images stay blocked. Links open in
/// the default browser.
struct HTMLView: NSViewRepresentable {
    let html: String
    var allowRemote = false

    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(src|background)\s*=\s*["']?\s*https?://|url\(\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "block-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) { list, _ in
            context.coordinator.blockList = list
            load(view, context.coordinator)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        // Before the block list is compiled, makeNSView's completion does the first load.
        guard coordinator.blockList != nil else { return }
        if coordinator.loaded != html || coordinator.remote != allowRemote { load(view, coordinator) }
    }

    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        if !allowRemote, let list = coordinator.blockList { controller.add(list) }
        coordinator.loaded = html
        coordinator.remote = allowRemote
        view.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    static func wrap(_ html: String) -> String {
        """
        <meta name="color-scheme" content="light dark">
        <style>body{font:14px -apple-system,sans-serif;margin:24px;line-height:1.5;word-wrap:break-word}img{max-width:100%}</style>
        \(html)
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        var remote = false
        var blockList: WKContentRuleList?

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// Reply suggestions from the bot: each chip opens a ready reply to edit and
/// send. Hidden when there is nothing to suggest.
struct SuggestionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let replies = model.insights?.replies ?? []
        if model.me?.can(.send) == true, model.insightsLoading || !replies.isEmpty || model.insights == nil {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                if model.insightsLoading {
                    Text("Antwoorden bedenken…").foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                } else if replies.isEmpty {
                    Button("Stel antwoorden voor") { Task { await model.loadInsights() } }
                        .buttonStyle(.borderless)
                } else {
                    ForEach(replies, id: \.self) { reply in
                        Button(reply.label) {
                            if let draft = model.compose(reply: reply) { openWindow(value: draft) }
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                        .fixedSize()
                    }
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
