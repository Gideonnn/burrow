import HedwigCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AgentSettings().tabItem { Label("Agent", systemImage: "sparkles") }
            AccountSettings().tabItem { Label("Accounts", systemImage: "tray.2") }
            ConnectionSettings().tabItem { Label("Verbinding", systemImage: "key") }
        }
        .padding(20)
    }
}

/// The person's standing instructions for their bots, and the rules learned
/// from restoring filtered mail.
struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var rules: [LearnedRule] = []
    @State private var saved = false

    var body: some View {
        Form {
            Section("Instructies") {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 150)
                HStack {
                    Text("Schrijf het zoals je het tegen een assistent zou zeggen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if saved { Text("Bewaard").font(.caption).foregroundStyle(.green) }
                    Button("Bewaar") {
                        Task {
                            try? await model.api?.setInstructions(text)
                            saved = true
                        }
                    }
                    .disabled(model.me?.can(.organize) != true)
                }
            }
            Section("Geleerd van jouw controles") {
                if rules.isEmpty { Text("Nog niets geleerd.").foregroundStyle(.secondary) }
                ForEach(rules) { rule in
                    HStack {
                        Text(rule.text)
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                try? await model.api?.deleteRule(rule.id)
                                rules = (try? await model.api?.rules()) ?? []
                            }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: text) { saved = false }
        .task {
            text = (try? await model.api?.instructions()) ?? ""
            rules = (try? await model.api?.rules()) ?? []
        }
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var people: [Person] = []
    @State private var personId = ""
    @State private var fastmailToken = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Mailboxen van deze sleutel") {
                ForEach(model.me?.mailboxes ?? []) { box in
                    LabeledContent(box.address, value: box.provider.rawValue)
                }
            }
            if model.me?.can(.admin) == true {
                Section("Account toevoegen") {
                    Picker("Voor", selection: $personId) {
                        ForEach(people) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button("Google") { Task { await connect(.gmail) } }
                        Button("Microsoft") { Task { await connect(.microsoft) } }
                    }
                    Text("Je browser opent het inlogscherm van Google of Microsoft. Je wachtwoord komt nooit bij Burrow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        SecureField("Fastmail API-token", text: $fastmailToken)
                        Button("Koppel Fastmail") { Task { await addFastmail() } }
                            .disabled(fastmailToken.isEmpty)
                    }
                    if let message { Text(message).font(.caption) }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard model.me?.can(.admin) == true else { return }
            people = (try? await model.api?.people()) ?? []
            personId = model.me?.person.id ?? people.first?.id ?? ""
        }
    }

    private func connect(_ provider: MailProvider) async {
        do {
            guard let url = try await model.api?.connectLink(personId: personId, provider: provider) else { return }
            NSWorkspace.shared.open(url)
            message = "Rond het inloggen af in je browser; de mailbox verschijnt daarna vanzelf."
        } catch {
            message = error.localizedDescription
        }
    }

    private func addFastmail() async {
        do {
            try await model.api?.addFastmail(personId: personId, token: fastmailToken)
            fastmailToken = ""
            message = "Fastmail is gekoppeld."
            await model.start()
        } catch {
            message = error.localizedDescription
        }
    }
}

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Server", value: model.connection?.serverURL.absoluteString ?? "")
            LabeledContent("Sleutel", value: model.me?.key.name ?? "")
            LabeledContent("Persoon", value: model.me?.person.name ?? "")
            LabeledContent("Rechten", value: (model.me?.rights ?? []).map(\.rawValue).joined(separator: ", "))
            Button("Verbinding verbreken", role: .destructive) { model.disconnect() }
        }
        .formStyle(.grouped)
    }
}
