import AppKit
import BurrowKit
import SwiftUI

/// The first screen of every Burrow app: log in through the browser with the
/// household's own login (Cloudflare Access), so nobody types or copies a key.
/// A key can still be pasted, for a server without Access.
public struct LoginView: View {
    let appName: String
    let app: String
    let accent: Color
    let connect: (URL, String) async throws -> Void

    @State private var server = SharedServer.last?.absoluteString ?? ""
    @State private var showKey = false
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?

    /// `connect` stores the server address and the new key and starts the app.
    public init(appName: String, app: String, accent: Color, connect: @escaping (URL, String) async throws -> Void) {
        self.appName = appName
        self.app = app
        self.accent = accent
        self.connect = connect
    }

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "house.lodge")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(accent)
            VStack(spacing: 6) {
                Text("Inloggen met je huishouden").font(.title2.weight(.semibold))
                Text("\(appName) opent je browser. Log daar in zoals altijd en druk op Toestaan; \(appName) krijgt dan een eigen sleutel voor deze Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            TextField("Adres van je server, zoals https://burrow.voorbeeld.nl", text: $server)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .accessibilityIdentifier("\(app).server")
            if showKey {
                SecureField("API-sleutel (bk_…)", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 380)
                    .accessibilityIdentifier("\(app).secret.key")
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(BurrowColor.danger).frame(maxWidth: 380)
            }
            HStack(spacing: 12) {
                Button(showKey ? "Gebruik de browser" : "Met een sleutel") {
                    showKey.toggle()
                    error = nil
                }
                .buttonStyle(.link)
                Spacer()
                Button {
                    Task { await go() }
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(showKey ? "Verbind" : "Inloggen in de browser")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || serverURL == nil || (showKey && key.isEmpty))
            }
            .frame(width: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serverURL: URL? {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.host() == "127.0.0.1" || url.host() == "localhost" else {
            return nil
        }
        return url
    }

    private func go() async {
        guard let url = serverURL else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            if showKey {
                try await connect(url, key.trimmingCharacters(in: .whitespaces))
            } else {
                let result = try await DeviceLogin(server: url, app: app).run { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                try await connect(url, result.token)
                NSApp.activate()
            }
            SharedServer.last = url
        } catch {
            self.error = error.localizedDescription
        }
    }
}
