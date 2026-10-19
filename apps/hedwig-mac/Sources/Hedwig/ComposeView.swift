import HedwigCore
import SwiftUI

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: ComposeDraft
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Van", selection: $draft.mailboxId) {
                    ForEach(model.me?.mailboxes ?? []) { box in Text(box.address).tag(box.id) }
                }
                .disabled(draft.inReplyTo != nil)
                TextField("Aan", text: $draft.to)
                TextField("Cc", text: $draft.cc)
                TextField("Onderwerp", text: $draft.subject)
            }
            .formStyle(.columns)
            .padding(16)
            Divider()
            TextEditor(text: $draft.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
            Divider()
            HStack {
                if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }
                Button {
                    Task { await send() }
                } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label("Verstuur", systemImage: "paperplane") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(Address.parseList(draft.to).isEmpty || sending || model.me?.can(.send) != true)
            }
            .padding(12)
        }
        .navigationTitle(draft.subject.isEmpty ? "Nieuw bericht" : draft.subject)
    }

    private func send() async {
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await model.send(draft)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
