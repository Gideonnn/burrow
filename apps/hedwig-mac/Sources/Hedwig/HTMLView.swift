import AppKit
import SwiftUI
import WebKit

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
