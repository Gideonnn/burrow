import HedwigCore
import SwiftUI

/// Tasks started by routines: what a bot proposes, waiting for approval, and
/// what already ran. Waiting ones come first.
struct TaskListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedTaskId) {
            ForEach(ordered) { task in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(task.routineName).font(.headline).lineLimit(1)
                        Spacer()
                        Text(shortDate(task.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = task.result?.summary {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    } else if let error = task.error {
                        Text(error).font(.subheadline).foregroundStyle(.red).lineLimit(2)
                    }
                    HStack(spacing: 5) {
                        Tag(text: statusName(task), color: statusColor(task))
                        Tag(text: task.where == "client" ? "Deze Mac" : "Server", color: .secondary)
                    }
                }
                .padding(.vertical, 4)
                .tag(task.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.tasks.isEmpty {
                ContentUnavailableView(
                    "Geen taken", systemImage: "checklist",
                    description: Text("Routines zetten hier hun voorstellen klaar."))
            }
        }
        .navigationTitle("Taken")
        .navigationSubtitle(model.runner.status)
        .task { await model.refreshTasks() }
    }

    private var ordered: [TaskItem] {
        let rank = ["review": 0, "running": 1, "queued": 1]
        return model.tasks.sorted { (rank[$0.status] ?? 2) < (rank[$1.status] ?? 2) }
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let task = model.tasks.first(where: { $0.id == model.selectedTaskId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "checklist").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(task.routineName).font(.title2.weight(.semibold))
                            Text("\(statusName(task)) · \(task.bot) met \(task.skill)").foregroundStyle(.secondary)
                        }
                    }
                    if let result = task.result {
                        Text(result.summary)
                        if !result.fields.isEmpty {
                            Grid(alignment: .leading, verticalSpacing: 6) {
                                ForEach(result.fields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    GridRow {
                                        Text(key).foregroundStyle(.secondary)
                                        Text(value).textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if !result.ops.isEmpty {
                            Label("Bij goedkeuren: \(result.ops.map(opName).joined(separator: ", "))", systemImage: "server.rack")
                                .font(.callout)
                        }
                        if let draft = result.draft {
                            GroupBox("Concept aan \(Address.format(draft.to))") {
                                Text(draft.body).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if let error = task.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    if task.status == "review" {
                        HStack {
                            Button("Goedkeuren") { Task { await model.approve(task) } }
                                .buttonStyle(.borderedProminent)
                            Button("Afwijzen", role: .destructive) { Task { await model.reject(task) } }
                        }
                        .disabled(model.me?.can(.organize) != true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Geen taak geselecteerd", systemImage: "checklist")
        }
    }
}

func statusName(_ task: TaskItem) -> String {
    switch task.status {
    case "queued": task.where == "client" ? "Wacht op deze Mac" : "In de wachtrij"
    case "running": "Bezig op \(task.claimedBy ?? "een runner")"
    case "review": "Wacht op jou"
    case "done": "Klaar"
    case "rejected": "Afgewezen"
    case "failed": "Mislukt"
    default: task.status
    }
}

func statusColor(_ task: TaskItem) -> Color {
    switch task.status {
    case "review": .orange
    case "running", "queued": .blue
    case "done": .green
    case "failed": .red
    default: .secondary
    }
}

func opName(_ op: ServerOp) -> String {
    switch op {
    case .archive: "archiveren"
    case .moveToSpam: "naar spam"
    case .moveToInbox: "terug naar inbox"
    case .markRead: "gelezen"
    case .markUnread: "ongelezen"
    case .flag: "vlag"
    case .unflag: "vlag weg"
    case .addLabel(let l): "label \(l)"
    case .removeLabel(let l): "label \(l) weg"
    case .trash: "verwijderen"
    }
}
