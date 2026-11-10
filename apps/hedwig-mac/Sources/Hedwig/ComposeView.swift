import AppKit
import HedwigCore
import SwiftUI

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: ComposeDraft
    @State private var original: ComposeDraft?
    @State private var sending = false
    @State private var failure: String?
    @State private var askingToClose = false
    @State private var closing = false
    @FocusState private var focus: Field?

    private enum Field { case to, body }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Van", selection: $draft.mailboxId) {
                    ForEach(model.me?.mailboxes ?? []) { box in Text(box.address).tag(box.id) }
                }
                .disabled(draft.inReplyTo != nil)
                TextField("Aan", text: $draft.to)
                    .focused($focus, equals: .to)
                TextField("Cc", text: $draft.cc)
                TextField("Onderwerp", text: $draft.subject)
            }
            .formStyle(.columns)
            .padding(16)
            Divider()
            TextEditor(text: $draft.body)
                .focused($focus, equals: .body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuleer") { requestClose() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await send() } } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label("Verstuur", systemImage: "paperplane") }
                }
                .accessibilityIdentifier("hedwig.send")
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Verstuur (⇧⌘D)")
                .disabled(!canSend)
            }
        }
        // ⌘↩ sent before Versturen moved to the toolbar; it still does.
        .background {
            Button("Verstuur") { Task { await send() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .hidden()
        }
        .navigationTitle(draft.subject.isEmpty ? "Nieuw bericht" : draft.subject)
        .background(CloseGuard(shouldClose: { closing || !edited }, onRefused: { askingToClose = true }))
        .alert("Concept bewaren?", isPresented: $askingToClose) {
            Button("Bewaar") { Task { await saveAndClose() } }
                .disabled(model.me?.can(.draft) != true)
            Button("Verwijder", role: .destructive) { close() }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Een bewaard concept staat onder Concepten van de mailbox.")
        }
        // A reply starts in the text, a new message at Aan.
        .defaultFocus($focus, draft.to.isEmpty ? .to : .body)
        .onAppear {
            if original == nil { original = draft }
            model.composing += 1
        }
        .onDisappear { model.composing -= 1 }
    }

    private var canSend: Bool { !Address.parseList(draft.to).isEmpty && !sending && model.me?.can(.send) == true }

    private var edited: Bool { original.map { $0 != draft } ?? false }

    private func requestClose() {
        if edited { askingToClose = true } else { close() }
    }

    private func close() {
        closing = true
        dismiss()
    }

    private func saveAndClose() async {
        do {
            try await model.saveDraft(draft)
            close()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func send() async {
        guard canSend else { return }
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await model.send(draft)
            close()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Asks before the window closes (the close button, ⌘W), which SwiftUI cannot do.
/// It stands in as the window's delegate and hands everything else to SwiftUI's.
private struct CloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool
    let onRefused: () -> Void

    func makeNSView(context: Context) -> GuardView { GuardView() }

    func updateNSView(_ view: GuardView, context: Context) {
        view.proxy.shouldClose = shouldClose
        view.proxy.onRefused = onRefused
    }

    final class GuardView: NSView {
        let proxy = DelegateProxy()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.delegate is DelegateProxy) else { return }
            proxy.original = window.delegate
            window.delegate = proxy
        }
    }

    final class DelegateProxy: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        var shouldClose: () -> Bool = { true }
        var onRefused: () -> Void = {}

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else {
                onRefused()
                return false
            }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { original }
    }
}
