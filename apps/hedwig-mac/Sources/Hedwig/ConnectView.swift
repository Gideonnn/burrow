import HedwigCore
import SwiftUI

/// The first screen on a new Mac: server address and API key.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var server = "http://127.0.0.1:4717"
    @State private var key = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Verbind met je mailserver").font(.title2.weight(.semibold))
                Text("Vraag een sleutel aan je beheerder, of maak er een met `cli init` op de server.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Form {
                TextField("Serveradres", text: $server)
                SecureField("API-sleutel", text: $key)
            }
            .formStyle(.grouped)
            .frame(width: 420)
            .disabled(busy)

            if let failure {
                Text(failure).foregroundStyle(.red).font(.callout)
            }

            Button {
                Task { await connect() }
            } label: {
                if busy { ProgressView().controlSize(.small) } else { Text("Verbinden") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(key.isEmpty || URL(string: server) == nil || busy)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() async {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)) else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await model.connect(serverURL: url, token: key.trimmingCharacters(in: .whitespaces))
        } catch {
            failure = error.localizedDescription
        }
    }
}
