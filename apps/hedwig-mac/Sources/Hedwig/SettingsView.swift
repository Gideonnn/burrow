import HedwigCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            AgentSettings().tabItem { Label("Agent", systemImage: "sparkles") }
            AccountSettings().tabItem { Label("Accounts", systemImage: "tray.2") }
            if model.me?.can(.admin) == true {
                AccessSettings().tabItem { Label("Toegang", systemImage: "person.2") }
            }
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
    @State private var language = ""

    var body: some View {
        Form {
            Section("Profiel van \(model.me?.person.name ?? "")") {
                HStack {
                    TextField("Taal van de bots", text: $language, prompt: Text("Standaard van de server"))
                        .onSubmit { Task { try? await model.setLanguage(language) } }
                    Button("Bewaar") { Task { try? await model.setLanguage(language) } }
                }
                Text("Bijvoorbeeld Nederlands of English. Geldt voor jouw mailboxen, op elke Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.me?.can(.organize) != true)
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
            Section("Taken op deze Mac") {
                Toggle("Deze Mac voert taken uit zolang Hedwig open is", isOn: Binding(get: { model.runsTasks }, set: { model.runsTasks = $0 }))
                    .disabled(model.me?.can(.tasks) != true)
                TextField("Pad naar claude (leeg: zoek zelf)", text: Binding(get: { model.claudePath }, set: { model.claudePath = $0 }))
                LabeledContent("Status", value: model.runner.status)
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
            language = model.me?.language ?? ""
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
                    MailboxSettingsRow(box: box)
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

/// Name and role of one mailbox; saved when the name is submitted or the role changes.
struct MailboxSettingsRow: View {
    @Environment(AppModel.self) private var model
    let box: MailboxSummary
    @State private var name = ""
    @State private var instructions = ""
    @State private var editing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(box.address, text: $name, prompt: Text(providerName(box)))
                    .onSubmit { save(name: name) }
                Picker("", selection: Binding(get: { box.kind }, set: { save(role: $0) })) {
                    ForEach(MailboxRole.allCases, id: \.self) { Text(roleTitle($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("\(box.address) · \(providerName(box))").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Instructies voor deze mailbox", isExpanded: $editing) {
                TextEditor(text: $instructions)
                    .font(.body)
                    .frame(minHeight: 70)
                HStack {
                    Text("Bijvoorbeeld: klantmail nooit archiveren.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Bewaar") { save(instructions: instructions) }
                }
            }
            .font(.caption)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .disabled(model.me?.can(.organize) != true)
        .onAppear {
            name = box.name == box.address ? "" : box.name
            instructions = box.instructions ?? ""
        }
    }

    private func save(name: String? = nil, role: MailboxRole? = nil, instructions: String? = nil) {
        Task {
            do {
                let trimmed = name?.trimmingCharacters(in: .whitespaces)
                try await model.updateMailbox(
                    box.id, name: trimmed.map { $0.isEmpty ? box.address : $0 }, role: role, instructions: instructions)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
