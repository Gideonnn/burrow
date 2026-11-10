import HedwigCore
import SwiftUI

struct OpenMessage: Codable, Hashable {
    let id: String
}

/// A message in a window of its own, like double-clicking in Mail. It reads
/// without marking or loading remote images unless Instellingen says always.
struct MessageWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(remoteImagesKey) private var loadRemoteImages = false
    let id: String
    @State private var message: MessageDetail?
    @State private var failure: String?
    @State private var bodyHeight: CGFloat = 200

    var body: some View {
        Group {
            if let message {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        MessageHeader(message: message)
                            .padding(.horizontal, 28)
                            .padding(.top, 18)
                            .padding(.bottom, 16)
                        Divider().padding(.horizontal, 28)
                        MessageBody(message: message, allowRemote: message.mayLoadRemoteImages && loadRemoteImages, height: $bodyHeight)
                    }
                }
            } else if let failure {
                ContentUnavailableView("Bericht niet geladen", systemImage: "envelope", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(message?.subject ?? "Bericht")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button { compose(all: false, forwarding: false) } label: {
                        Label("Beantwoord", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Beantwoord")
                    Button { compose(all: true, forwarding: false) } label: {
                        Label("Allen beantwoorden", systemImage: "arrowshape.turn.up.left.2")
                    }
                    .help("Allen beantwoorden")
                    Button { compose(all: false, forwarding: true) } label: {
                        Label("Stuur door", systemImage: "arrowshape.turn.up.right")
                    }
                    .help("Stuur door")
                }
                .controlGroupStyle(.navigation)
                .disabled(message == nil || message?.share?.by != nil || model.me?.can(.send) != true)
            }
        }
        .task(id: id) {
            guard let api = model.api else { return }
            do {
                message = try await api.message(id: id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func compose(all: Bool, forwarding: Bool) {
        Task {
            if let draft = await model.draft(replyingTo: id, all: all, forwarding: forwarding) { openWindow(value: draft) }
        }
    }
}
