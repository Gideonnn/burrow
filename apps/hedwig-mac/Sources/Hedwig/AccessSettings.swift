import HedwigCore
import SwiftUI

/// People, their mailboxes and every API key: who sees what. Only for keys
/// with the admin right. A new key is shown once and is always for the person
/// making it; the other person logs in on their own Mac.
struct AccessSettings: View {
    @Environment(AppModel.self) private var model
    @State private var people: [Person] = []
    @State private var mailboxes: [MailboxSummary] = []
    @State private var keys: [ApiKeySummary] = []
    @State private var newPerson = ""
    @State private var creating = false
    @State private var created: CreatedKey?
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Personen") {
                ForEach(people) { person in
                    LabeledContent(person.name) {
                        Text(mailboxes.filter { $0.ownerId == person.id }.map(\.address).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Nieuwe persoon", text: $newPerson)
                    Button("Voeg toe") { Task { await addPerson() } }.disabled(newPerson.isEmpty)
                }
            }
            Section("Sleutels") {
                ForEach(keys) { key in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name).strikethrough(key.revokedAt != nil)
                            Text(describe(key)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if key.revokedAt == nil, key.id != model.me?.key.id {
                            Button("Intrekken", role: .destructive) { Task { await revoke(key) } }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Nieuwe sleutel…") { creating = true }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .task { await load() }
        .sheet(isPresented: $creating) {
            NewKeySheet(people: people, mailboxes: mailboxes) { result in
                created = result
                Task { await load() }
            }
        }
        .alert("Sleutel gemaakt", isPresented: Binding(get: { created != nil }, set: { if !$0 { created = nil } })) {
            Button("Kopieer") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(created?.token ?? "", forType: .string)
            }
            .accessibilityIdentifier("hedwig.secret.copy")
            Button("Klaar", role: .cancel) {}
        } message: {
            Text("Je ziet hem maar één keer; de server bewaart alleen een hash.\n\n\(created?.token ?? "")")
                .accessibilityIdentifier("hedwig.secret.token")
        }
    }

    private func describe(_ key: ApiKeySummary) -> String {
        let person = people.first { $0.id == key.personId }?.name ?? "?"
        let boxes = key.mailboxIds.map { ids in
            mailboxes.filter { ids.contains($0.id) }.map(\.address).joined(separator: ", ")
        } ?? "alle mailboxen"
        let state = key.revokedAt != nil ? "ingetrokken" : key.lastUsedAt.map { "gebruikt \(shortDate($0))" } ?? "nog niet gebruikt"
        return "\(person) · \(boxes) · \(key.rights.map(rightName).joined(separator: ", ")) · \(state)"
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            async let p = api.people()
            async let m = api.allMailboxes()
            async let k = api.keys()
            (people, mailboxes, keys) = try await (p, m, k)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func addPerson() async {
        do {
            _ = try await model.api?.addPerson(name: newPerson)
            newPerson = ""
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func revoke(_ key: ApiKeySummary) async {
        do {
            try await model.api?.revokeKey(key.id)
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct NewKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let people: [Person]
    let mailboxes: [MailboxSummary]
    let onCreated: (CreatedKey) -> Void

    @State private var name = ""
    @State private var personId = ""
    @State private var allMailboxes = true
    @State private var chosen: Set<String> = []
    @State private var rights: Set<Right> = [.read, .organize, .draft]
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nieuwe sleutel").font(.title3.weight(.semibold))
            Text("Voor een apparaat of een agent. De sleutel ziet alleen wat je hier aanvinkt.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Naam", text: $name, prompt: Text("Bijvoorbeeld: Claude Code werklaptop"))
                Text("Een sleutel is altijd voor jezelf: hij leest jouw mail. Iemand anders logt op zijn eigen Mac in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Al mijn mailboxen, ook later toegevoegde", isOn: $allMailboxes)
                if !allMailboxes {
                    ForEach(mailboxes.filter { $0.ownerId == personId }) { box in
                        Toggle(box.address, isOn: Binding(
                            get: { chosen.contains(box.id) },
                            set: { if $0 { chosen.insert(box.id) } else { chosen.remove(box.id) } }))
                    }
                }
                ForEach(Right.allCases, id: \.self) { right in
                    Toggle(rightName(right), isOn: Binding(
                        get: { rights.contains(right) },
                        set: { if $0 { rights.insert(right) } else { rights.remove(right) } }))
                }
            }
            .formStyle(.grouped)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }
                Button("Maak sleutel") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || personId.isEmpty || rights.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 600)
        .onAppear { personId = model.me?.person.id ?? "" }
    }

    private func create() async {
        do {
            guard let result = try await model.api?.createKey(
                personId: personId, name: name, rights: Right.allCases.filter(rights.contains),
                mailboxIds: allMailboxes ? nil : Array(chosen))
            else { return }
            dismiss()
            onCreated(result)
        } catch {
            failure = error.localizedDescription
        }
    }
}

func rightName(_ right: Right) -> String {
    switch right {
    case .read: "Lezen"
    case .organize: "Ordenen"
    case .draft: "Concepten"
    case .send: "Versturen"
    case .tasks: "Taken uitvoeren"
    case .admin: "Beheer"
    }
}
