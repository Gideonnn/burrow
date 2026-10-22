import BurrowUI
import PensieveCore
import SwiftUI

/// Three columns like Mail: where (all, mine, shared), the recordings, and
/// the open one. While recording, the detail becomes the capture surface.
struct MainView: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder
    @State private var request = NewRecordingRequest.shared

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            RecordingList()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
                .searchable(text: $model.query, prompt: "Zoek in opnames en transcripten")
                .onSubmit(of: .search) { Task { await model.reload() } }
                .onChange(of: model.query) { if model.query.isEmpty { Task { await model.reload() } } }
        } detail: {
            if recorder.isRecording {
                LiveRecordingView()
            } else if let detail = model.detail, detail.id == model.selectedId {
                RecordingDetailView(detail: detail)
            } else {
                ContentUnavailableView("Geen opname gekozen", systemImage: "waveform", description: Text("Kies links een opname, of neem er een op."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .sheet(isPresented: $request.open) { NewRecordingSheet() }
        .task { await model.reload() }
    }
}

struct RecordButton: View {
    @Environment(RecorderController.self) private var recorder

    var body: some View {
        if recorder.isRecording {
            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Stop opname", systemImage: "stop.fill")
            }
            .help("Stop opname (⌘.)")
            .accessibilityIdentifier("pensieve.stop")
        } else {
            Button {
                NewRecordingRequest.shared.open = true
            } label: {
                Label("Neem op", systemImage: "record.circle")
                    .foregroundStyle(BurrowColor.danger)
            }
            .help("Nieuwe opname (⌘N)")
            .accessibilityIdentifier("pensieve.record")
        }
    }
}

struct Sidebar: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.scope }, set: { if let s = $0 { model.scope = s } })) {
            Section("Opnames") {
                Label("Alle opnames", systemImage: "tray.full").tag(RecordingScope.all)
                Label("Van mij", systemImage: "person").tag(RecordingScope.mine)
                Label("Gedeeld met mij", systemImage: "person.2").tag(RecordingScope.shared)
            }
            if recorder.isRecording {
                Section("Nu") {
                    Label("\(recorder.title) · \(clock(recorder.elapsed))", systemImage: "record.circle.fill")
                        .foregroundStyle(BurrowColor.danger)
                }
            }
            if !model.pending.isEmpty {
                Section("Wacht op upload") {
                    ForEach(model.pending) { upload in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(upload.title).lineLimit(1)
                            if let progress = model.uploadProgress[upload.id] {
                                ProgressView(value: progress).controlSize(.small)
                            } else if upload.lastError != nil {
                                Text("Probeert het later opnieuw").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }
}

struct SidebarFooter: View {
    @Environment(PensieveModel.self) private var model
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ready = updater.ready {
                Button("Update klaar (\(ready)) · Herstart") { (NSApp.delegate as? AppDelegate)?.restart() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Circle().fill(reachable ? BurrowColor.success : BurrowColor.warning).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.connection?.serverURL.host() ?? "").font(.caption.weight(.semibold))
                    Text(reachable ? model.profile.map { "\($0.person.name) · \($0.key.name)" } ?? "" : "Server even niet bereikbaar")
                        .font(.caption2)
                        .foregroundStyle(reachable ? AnyShapeStyle(.secondary) : AnyShapeStyle(BurrowColor.warning))
                        .lineLimit(1)
                }
            }
            .help(reachable ? "Verbonden" : "Pensieve probeert het vanzelf opnieuw.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reachable: Bool { model.reachability.isReachable }
}

struct RecordingList: View {
    @Environment(PensieveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedId) {
            ForEach(groups, id: \.0) { title, rows in
                Section(title) {
                    ForEach(rows) { RecordingRow(recording: $0).tag($0.id) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.recordings.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "Nog geen opnames" : "Niets gevonden",
                    systemImage: "waveform",
                    description: Text(model.query.isEmpty ? "Druk op de rode knop (⌘N) om een gesprek op te nemen." : "Probeer andere woorden."))
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch model.scope {
        case .all: "Alle opnames"
        case .mine: "Van mij"
        case .shared: "Gedeeld met mij"
        }
    }

    /// Today, yesterday, this week, then per month.
    private var groups: [(String, [RecordingSummary])] {
        let calendar = Calendar.current
        let month = DateFormatter()
        month.dateFormat = "LLLL yyyy"
        month.locale = Locale(identifier: "nl_NL")
        var order: [String] = []
        var rows: [String: [RecordingSummary]] = [:]
        for r in model.recordings {
            let key: String
            if calendar.isDateInToday(r.startedAt) { key = "Vandaag" }
            else if calendar.isDateInYesterday(r.startedAt) { key = "Gisteren" }
            else if let week = calendar.dateInterval(of: .weekOfYear, for: Date()), week.contains(r.startedAt) { key = "Deze week" }
            else { key = month.string(from: r.startedAt).capitalized }
            if rows[key] == nil { order.append(key) }
            rows[key, default: []].append(r)
        }
        return order.map { ($0, rows[$0]!) }
    }
}

struct RecordingRow: View {
    let recording: RecordingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title).font(.headline).lineLimit(1)
                Spacer()
                Text(recording.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if recording.status == .done, let preview = recording.preview {
                Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else if recording.status == .failed {
                Text(recording.error ?? "Mislukt").font(.callout).foregroundStyle(BurrowColor.danger).lineLimit(2)
            }
            HStack(spacing: 6) {
                if recording.status != .done { StatusPill(recording.status.rawValue) }
                if let seconds = recording.durationSeconds {
                    Text(clock(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !recording.mine {
                    Label("Van \(recording.owner.name)", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                } else if !recording.sharedWith.isEmpty {
                    Label("Gedeeld", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                PersonBadge(recording.owner.name, size: 16)
            }
        }
        .padding(.vertical, 4)
    }
}
