import HedwigCore
import SwiftUI
import WebKit

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let message = model.detail {
            VStack(alignment: .leading, spacing: 0) {
                MessageHeader(message: message)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                Divider()
                if let html = message.bodyHtml {
                    HTMLView(html: html)
                } else {
                    ScrollView {
                        Text(message.bodyText ?? message.snippet)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                }
            }
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

/// Renders mail HTML without JavaScript and without loading anything from the
/// network, so trackers and remote images stay blocked. Links open in the
/// default browser.
struct HTMLView: NSViewRepresentable {
    let html: String

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
            if let list { view.configuration.userContentController.add(list) }
            view.loadHTMLString(Self.wrap(html), baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            view.loadHTMLString(Self.wrap(html), baseURL: nil)
        }
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
