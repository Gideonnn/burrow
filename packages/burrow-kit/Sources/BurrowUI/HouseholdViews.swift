import BurrowKit
import SwiftUI

/// Renders the settings modules declare, features first, without knowing them.
public struct SettingsForm: View {
    let schema: [SettingDefinition]
    let values: [String: SettingValue]
    let change: (String, SettingValue) -> Void

    public init(schema: [SettingDefinition], values: [String: SettingValue], change: @escaping (String, SettingValue) -> Void) {
        self.schema = schema
        self.values = values
        self.change = change
    }

    public var body: some View {
        let features = schema.filter(\.feature)
        let rest = schema.filter { !$0.feature }
        if !features.isEmpty {
            Section("Functies") { ForEach(features) { row($0) } }
        }
        if !rest.isEmpty {
            Section("Voorkeuren") { ForEach(rest) { row($0) } }
        }
    }

    @ViewBuilder
    private func row(_ d: SettingDefinition) -> some View {
        let current = values[d.key] ?? d.default
        VStack(alignment: .leading, spacing: 2) {
            switch d.type {
            case .boolean:
                Toggle(d.label, isOn: Binding(get: { current.bool ?? false }, set: { change(d.key, .bool($0)) }))
                    .accessibilityIdentifier("setting.\(d.key)")
            case .choice:
                Picker(d.label, selection: Binding(get: { current.string ?? "" }, set: { change(d.key, $0.isEmpty ? .null : .string($0)) })) {
                    if d.default == .null { Text("Standaard").tag("") }
                    ForEach(d.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("setting.\(d.key)")
            case .text:
                TextField(d.label, text: Binding(get: { current.string ?? "" }, set: { change(d.key, .string($0)) }))
                    .accessibilityIdentifier("setting.\(d.key)")
            }
            if let help = d.description {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings › Huishouden. An admin picks a person and manages their features,
/// preferences and devices; nobody sees anyone else's mail or recordings here.
public struct HouseholdSettingsView: View {
    @Bindable var model: HouseholdModel
    @State private var personId: String?

    public init(model: HouseholdModel) { self.model = model }

    public var body: some View {
        Form {
            if model.isAdmin, model.members.count > 1 {
                Picker("Persoon", selection: Binding(get: { personId ?? model.myPersonId ?? "" }, set: { personId = $0 })) {
                    ForEach(model.members) { member in
                        Text(member.id == model.myPersonId ? "\(member.name) (jij)" : member.name).tag(member.id)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("household.person")
                Text("Je beheert ieders functies, voorkeuren en apparaten, maar leest nooit elkaars mail of opnames.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let who = personId ?? model.myPersonId
            SettingsForm(schema: model.schema, values: model.values(for: who ?? "")) { key, value in
                Task { await model.set(key, value, for: who) }
            }
            if let member = model.members.first(where: { $0.id == who }) {
                Section("Apparaten van \(member.name)") {
                    let active = member.keys.filter { $0.revokedAt == nil }
                    if active.isEmpty { Text("Geen apparaten").foregroundStyle(.secondary) }
                    ForEach(active) { key in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(key.name)
                                Text(key.lastUsedAt.map { "Laatst gebruikt \($0.formatted(.relative(presentation: .named)))" } ?? "Nog niet gebruikt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Trek in", role: .destructive) { Task { await model.revoke(key) } }
                                .accessibilityIdentifier("household.approve.revoke")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

/// Settings › Workers: the bots and what they are doing.
public struct WorkersView: View {
    @Bindable var model: HouseholdModel

    public init(model: HouseholdModel) { self.model = model }

    public var body: some View {
        Form {
            Section("Bots") {
                ForEach(model.catalog?.bots ?? []) { bot in
                    HStack(alignment: .top, spacing: 10) {
                        PersonBadge(bot.displayName, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bot.displayName).font(.headline)
                            Text(bot.description).font(.callout).foregroundStyle(.secondary)
                            Text("\(bot.skills.joined(separator: ", ")) · \(agentName(bot.agent)) · \(bot.model)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Recent werk") {
                if model.tasks.isEmpty { Text("Nog niets gedaan").foregroundStyle(.secondary) }
                ForEach(model.tasks.prefix(30)) { task in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.displayTitle)
                            if let text = task.error ?? task.result?.summary {
                                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if task.status == "failed" {
                            Button("Opnieuw") { Task { await model.retry(task) } }.controlSize(.small)
                        }
                        StatusPill(task.status)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }

    private func agentName(_ agent: String?) -> String {
        switch agent {
        case "claude": "Claude"
        case "codex": "Codex"
        default: "Claude of Codex"
        }
    }
}
