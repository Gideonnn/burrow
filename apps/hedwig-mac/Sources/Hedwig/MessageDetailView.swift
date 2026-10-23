import HedwigCore
import SwiftUI
import WebKit

/// The header scrolls with the message, as in Mail: one ScrollView holds the
/// header and a web view as tall as the mail, so the web view never scrolls
/// itself (see the diary, 2026-10-23-reader-header-scrolls-with-the-mail).
struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(remoteImagesKey) private var loadRemoteImages = false
    // The one message whose images the person chose to load.
    @State private var allowedMessageId: String?
    @State private var bodyHeight: CGFloat = 200

    private static let top = "top"

    var body: some View {
        if let message = model.detail {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            MessageHeader(message: message)
                            if model.showsOutingCard { OutingCard() }
                            ReviewBar(message: message)
                            if let summary = model.insights?.summary {
                                Label(summary, systemImage: "sparkles")
                                    .font(.callout)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if let html = message.bodyHtml, message.mayLoadRemoteImages {
                                RemoteImagesBar(html: html, messageId: message.id, allowed: $allowedMessageId, always: loadRemoteImages)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 16)
                        .id(Self.top)
                        Divider().padding(.horizontal, 28)
                        if let html = message.bodyHtml {
                            HTMLView(
                                html: html,
                                allowRemote: message.mayLoadRemoteImages && (loadRemoteImages || allowedMessageId == message.id),
                                height: $bodyHeight
                            )
                            .frame(height: bodyHeight)
                        } else {
                            // Mail's default message font.
                            Text(message.bodyText ?? message.snippet)
                                .font(.custom("Helvetica", size: 12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 20)
                        }
                    }
                }
                .onChange(of: message.id) { proxy.scrollTo(Self.top, anchor: .top) }
            }
            .safeAreaInset(edge: .bottom) { SuggestionBar() }
        } else {
            ContentUnavailableView("Geen bericht geselecteerd", systemImage: "envelope")
        }
    }
}

/// After Mail: the sender is the strongest line, the subject sits under it,
/// then compact Aan/Kopie/Antwoord aan lines. The date stays top right.
/// Mail sizes its header from the message font (12 pt): the sender at 14.
struct MessageHeader: View {
    let message: MessageDetail

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.from.display, size: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(message.from.display)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .help(message.from.email)
                        .contextMenu {
                            Button("Kopieer adres") { copy(message.from.email) }
                        }
                    Spacer(minLength: 0)
                    Text(MailFormat().headerDate(message.receivedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.bottom, 2)
                Text(message.subject)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                RecipientLinesView(lines: message.recipientLines)
                    .id(message.id)
                    .padding(.top, 2)
                MessageTags(message: message)
                if message.hasAttachments {
                    Label("Bevat bijlagen; open ze voorlopig in de webmail", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Names only; each line shows its addresses on hover. Long lists end in
/// "+3", which opens every line in full.
struct RecipientLinesView: View {
    let lines: [RecipientLine]
    @State private var expanded = false

    private static let limit = 3

    var body: some View {
        let compact = lines.filter { $0.kind != .replyTo }
        VStack(alignment: .leading, spacing: 2) {
            if expanded {
                ForEach(lines) { line in
                    RecipientText(line: line, limit: nil) {}
                }
                Button("Minder") { expanded = false }
                    .buttonStyle(.link)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        ForEach(compact) { line in
                            RecipientText(line: line, limit: Self.limit) { expanded = true }.fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(compact) { line in
                            RecipientText(line: line, limit: Self.limit) { expanded = true }
                        }
                    }
                }
                ForEach(lines.filter { $0.kind == .replyTo }) { line in
                    RecipientText(line: line, limit: Self.limit) { expanded = true }
                }
            }
        }
        .font(.callout)
    }
}

private struct RecipientText: View {
    let line: RecipientLine
    let limit: Int?
    let expand: () -> Void

    var body: some View {
        let names = line.names(limit: limit)
        // Mail: the label in the primary colour, the names in grey after a wide gap.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(line.label):").fixedSize()
            Text(names.shown)
                .foregroundStyle(.secondary)
                .lineLimit(limit == nil ? nil : 1)
                .truncationMode(.tail)
            if names.more > 0 {
                Button("+\(names.more)", action: expand)
                    .buttonStyle(.link)
                    .help("Toon iedereen")
            }
        }
        .help(line.tooltip)
        .contextMenu {
            Button("Kopieer adressen") { copy(line.addresses.map(\.email).joined(separator: ", ")) }
        }
    }
}

/// The same tags as the message row: category, Antwoord nodig, labels, and
/// the lock for sensitive mail.
private struct MessageTags: View {
    let message: MessageDetail

    var body: some View {
        let category = message.facts?.categoryTitle
        let sensitive = message.facts?.sensitive == true
        if category != nil || message.flagged || !message.labels.isEmpty || sensitive {
            HStack(spacing: 5) {
                if let category { Tag(text: category, color: .teal) }
                if message.flagged { Tag(text: "Antwoord nodig", color: .orange) }
                ForEach(message.labels, id: \.self) { Tag(text: $0, color: .secondary) }
                if sensitive {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .help("Bevat gevoelige gegevens; gaat nooit naar een cloud-AI")
                }
            }
            .padding(.top, 2)
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(initials.uppercased())
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Renders mail HTML without JavaScript. Unless `allowRemote`, nothing loads
/// from the network, so trackers and remote images stay blocked. Links open in
/// the default browser. It reports the mail's height, so the reader can make
/// it exactly that tall inside its own scroll view.
struct HTMLView: NSViewRepresentable {
    let html: String
    var allowRemote = false
    @Binding var height: CGFloat

    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(src|background)\s*=\s*["']?\s*https?://|url\(\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> MailWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Our own script runs in a separate world, which the switch above leaves alone.
        let controller = config.userContentController
        controller.addUserScript(
            WKUserScript(source: Self.measureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.add(WeakScriptHandler(context.coordinator), contentWorld: .defaultClient, name: Self.handlerName)
        let view = MailWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "block-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) { list, _ in
            context.coordinator.blockList = list
            load(view, context.coordinator)
        }
        return view
    }

    func updateNSView(_ view: MailWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.height = $height
        // Before the block list is compiled, makeNSView's completion does the first load.
        guard coordinator.blockList != nil else { return }
        if coordinator.loaded != html || coordinator.remote != allowRemote { load(view, coordinator) }
    }

    static func dismantleNSView(_ view: MailWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: .defaultClient)
    }

    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        if !allowRemote, let list = coordinator.blockList { controller.add(list) }
        coordinator.loaded = html
        coordinator.remote = allowRemote
        view.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    // The web view is as tall as the mail, so nothing may size itself to the
    // window: quirks mode (the mail's own doctype comes too late to count)
    // resolves `height="100%"` against it and the reader never grows shorter.
    // Almost-standards mode, which mail is written for, keeps the table image
    // quirk. The closing style wins over templates that pin html and body to
    // 100%; the end marker catches content past the body's box.
    static func wrap(_ html: String) -> String {
        """
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
        <meta name="color-scheme" content="light dark">
        <style>body{font:12px Helvetica,sans-serif;margin:20px 28px 24px;word-wrap:break-word}img{max-width:100%}</style>
        \(html)
        <style>html,html body{height:auto!important;min-height:0!important}html{overflow-y:hidden!important}</style>
        <div id="hedwig-end" style="clear:both;height:1px"></div>
        """
    }

    static let handlerName = "hedwig"

    static let measureScript = """
        (() => {
          const post = (message) => window.webkit.messageHandlers.\(handlerName).postMessage(message);
          let last = 0;
          const measure = () => {
            const body = document.body;
            if (!body) return;
            const end = document.getElementById('hedwig-end');
            const bottom = Math.max(body.getBoundingClientRect().bottom, end ? end.getBoundingClientRect().bottom : 0);
            const height = Math.ceil(bottom + window.scrollY + (parseFloat(getComputedStyle(body).marginBottom) || 0));
            if (height !== last) { last = height; post({ height }); }
          };
          new ResizeObserver(measure).observe(document.body);
          addEventListener('load', measure);
          measure();
          const editing = () => {
            const e = document.activeElement;
            post({ editing: !!e && (e.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.tagName)) });
          };
          addEventListener('focusin', editing);
          addEventListener('focusout', () => setTimeout(editing));
        })();
        """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded: String?
        var remote = false
        var blockList: WKContentRuleList?
        var height: Binding<CGFloat>
        weak var view: MailWebView?

        init(height: Binding<CGFloat>) { self.height = height }

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

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let value = body["height"] as? Double, value > 0, abs(height.wrappedValue - value) >= 1 {
                height.wrappedValue = value
            }
            if let editing = body["editing"] as? Bool { view?.editing = editing }
        }
    }
}

/// The user content controller keeps its handlers alive; this keeps it from
/// keeping the coordinator alive too.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A web view that is as tall as its mail: vertical scrolling and the scroll
/// keys go to the reader's scroll view, so header and mail move as one.
final class MailWebView: WKWebView {
    var editing = false

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !editing, let outer = enclosingScrollView, let move = ScrollKey(event) {
            move.apply(to: outer)
        } else {
            super.keyDown(with: event)
        }
    }

    // Selecting text past the bottom of the window scrolls the reader along.
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        autoscroll(with: event)
    }
}

private enum ScrollKey {
    case page(CGFloat), line(CGFloat), top, bottom

    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch (event.keyCode, modifiers) {
        case (49, []), (121, []): self = .page(1)
        case (49, [.shift]), (116, []): self = .page(-1)
        case (125, []): self = .line(1)
        case (126, []): self = .line(-1)
        case (115, []), (126, [.command]): self = .top
        case (119, []), (125, [.command]): self = .bottom
        default: return nil
        }
    }

    @MainActor func apply(to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let flipped = scrollView.documentView?.isFlipped ?? true
        let visible = clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
        let down: CGFloat = switch self {
        case .page(let direction): direction * max(visible - 40, 40)
        case .line(let direction): direction * 40
        case .top: -1e9
        case .bottom: 1e9
        }
        var origin = clip.bounds.origin
        origin.y += flipped ? down : -down
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        if case .line = self {
            clip.scroll(to: target)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                clip.animator().setBoundsOrigin(target)
            }
        }
        scrollView.reflectScrolledClipView(clip)
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
