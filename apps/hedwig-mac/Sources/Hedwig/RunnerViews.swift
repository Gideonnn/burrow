import HedwigCore
import SwiftUI

/// Every runner of the household and the work waiting for this person.
struct RunnersSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Runners") {
                let all = model.runners?.runners ?? []
                if all.isEmpty { Text("Geen runners bekend.").foregroundStyle(.secondary) }
                ForEach(all) { runner in RunnerRow(runner: runner) }
            }
            Section("Wacht op een runner") {
                let work = model.runners?.work ?? []
                if work.isEmpty { Text("Niets in de wachtrij.").foregroundStyle(.secondary) }
                ForEach(work) { item in
                    LabeledContent(item.progress, value: queueTitle(item.queue))
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshRunners() }
    }
}

/// One runner: who it belongs to, whether it is online, what it serves, and a
/// switch for the person's own runners (or the server's, for an admin).
struct RunnerRow: View {
    @Environment(AppModel.self) private var model
    let runner: RunnerInfo

    var body: some View {
        HStack(alignment: .top) {
            Circle()
                .fill(runner.online ? (runner.paused ? Color.orange : .green) : .secondary)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(runner.name + (runner.personName.map { " (\($0))" } ?? ""))
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if mayPause {
                Toggle("Aan", isOn: Binding(
                    get: { !runner.paused },
                    set: { on in Task { await model.setRunner(runner, paused: !on) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private var mayPause: Bool {
        runner.mine ? model.me?.can(.tasks) == true : runner.personName == nil && model.me?.can(.admin) == true
    }

    private var details: String {
        var parts = [runner.online ? (runner.paused ? "gepauzeerd" : "online") : "offline"]
        parts.append(runner.queues.map(queueTitle).joined(separator: " en "))
        if let doing = runner.doing { parts.append(doing) }
        if !runner.online, let seen = runner.lastSeenAt { parts.append("laatst gezien \(shortDate(seen))") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

func queueTitle(_ queue: String) -> String {
    queue == "local" ? "lokaal" : "cloud"
}
