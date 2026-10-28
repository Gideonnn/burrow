import AVFoundation
import BurrowUI
import PensieveCore
import SwiftUI

/// Three columns like Hedwig: the kinds, the recordings, and the open one.
/// While recording, the detail becomes the recording stage.
struct MainView: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder
    @State private var shrink = ShrinkRequest.shared

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            RecordingList()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 480)
                // As in Hedwig: an item here makes SwiftUI track the divider, so the
                // detail's toolbar starts at that column's leading edge.
                .toolbar {
                    if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
                    ToolbarItem { LabelFilterButton() }
                }
        } detail: {
            Group {
                if recorder.isRecording {
                    LiveRecordingView()
                } else if let detail = model.detail, detail.id == model.selectedId {
                    RecordingDetailView(detail: detail).id(detail.id)
                } else {
                    ContentUnavailableView("Geen opname gekozen", systemImage: "waveform", description: Text("Kies een opname, of neem er een op."))
                }
            }
            .toolbar { MainToolbar() }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Zoek")
        .onSubmit(of: .search) { Task { await model.reload() } }
        .onChange(of: model.query) { if model.query.isEmpty { Task { await model.reload() } } }
        .sheet(item: $shrink.source) { ShrinkSheet(source: $0.url) }
        .task { await model.reload() }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder

    var body: some View {
        // Like Hedwig's: a click beside a row never leaves the list without a place.
        List(selection: Binding(get: { model.kindFilter.map(Place.kind) ?? .all }, set: { place in
            switch place {
            case .all: model.kindFilter = nil
            case .kind(let kind): model.kindFilter = kind
            case nil: break
            }
        })) {
            Section {
                CountedLabel(title: "Alle opnames", icon: "square.grid.2x2", count: model.all.count).tag(Place.all)
            } header: {
                SidebarSectionHeader("Opnames")
            }
            Section {
                ForEach(RecordingKind.allCases, id: \.self) { kind in
                    CountedLabel(title: kind.plural, icon: kind.symbol, count: model.count(of: kind)).tag(Place.kind(kind))
                }
            } header: {
                SidebarSectionHeader("Soort")
            }
            if recorder.isRecording {
                Section {
                    Label("\(recorder.title) · \(clock(recorder.elapsed))", systemImage: "record.circle.fill")
                        .foregroundStyle(BurrowColor.danger)
                        .selectionDisabled()
                } header: {
                    SidebarSectionHeader("Nu")
                }
            }
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { upload in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(upload.title, systemImage: "icloud.and.arrow.up").lineLimit(1)
                            if let progress = model.uploadProgress[upload.id] {
                                ProgressView(value: progress).controlSize(.small)
                            } else if upload.lastError != nil {
                                Text("Probeert het later opnieuw").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .selectionDisabled()
                    }
                } header: {
                    SidebarSectionHeader("Wacht op upload")
                }
            }
            Section {
                Button { ShrinkRequest.shared.choose() } label: {
                    Label("Verklein een video…", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            } header: {
                SidebarSectionHeader("Hulpmiddelen")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UpdateBanner(appName: "Pensieve") { (NSApp.delegate as? AppDelegate)?.restart() }
                ConnectionBadge(
                    host: model.connection?.serverURL.host() ?? "",
                    detail: model.pending.isEmpty ? "iCloud en Dobby zijn bij" : "\(model.pending.count) wacht op upload",
                    reachable: model.reachability.isReachable, busy: !model.uploadProgress.isEmpty, appName: "Pensieve")
            }
        }
    }

    enum Place: Hashable {
        case all
        case kind(RecordingKind)
    }
}

// MARK: Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(PensieveModel.self) private var model

    // Hedwig's layout: the main action at the detail's leading edge, the
    // recording's actions as one group before the search field.
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem { RecordButton() }
            ToolbarSpacer(.flexible)
            ToolbarItem { RecordingActions() }
        } else {
            ToolbarItem(placement: .navigation) { RecordButton() }
            ToolbarItem(placement: .primaryAction) { RecordingActions() }
        }
    }
}

/// Records the kind of last time; the arrow picks another.
struct RecordButton: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder
    @AppStorage(RecordingKind.lastKey) private var last = RecordingKind.call.rawValue

    var body: some View {
        if recorder.isRecording {
            Button { Task { await recorder.stop() } } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .labelStyle(.titleAndIcon)
            }
            .help("Stop de opname (⌘.)")
            .accessibilityIdentifier("pensieve.stop")
        } else {
            let kind = RecordingKind(rawValue: last) ?? .call
            Menu {
                ForEach(RecordingKind.recordable, id: \.self) { other in
                    Button { record(other, model: model, recorder: recorder) } label: {
                        Label(other.title, systemImage: other.symbol)
                    }
                }
                Divider()
                Text("Dicteren: houd ⌥ Spatie ingedrukt")
            } label: {
                Label {
                    Text(kind.title)
                } icon: {
                    Image(systemName: "record.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                }
                .labelStyle(.titleAndIcon)
            } primaryAction: {
                record(kind, model: model, recorder: recorder)
            }
            .help("Neem een \(kind.title.lowercased()) op (⌘N); het pijltje kiest een andere soort")
            .disabled(model.connection == nil)
            .accessibilityIdentifier("pensieve.record")
        }
    }
}

/// Starts a recording of this kind and remembers it for the red button.
@MainActor
func record(_ kind: RecordingKind, model: PensieveModel, recorder: RecorderController) {
    UserDefaults.standard.set(kind.rawValue, forKey: RecordingKind.lastKey)
    Task {
        await recorder.start(kind)
        if let error = recorder.error {
            model.error = error
            recorder.error = nil
        }
    }
}

/// Stuur, Verklein and Toon in Finder for the open recording.
struct RecordingActions: View {
    @Environment(PensieveModel.self) private var model

    var body: some View {
        let id = model.detail?.id
        let file = id.flatMap(model.file(of:))
        let video = id.flatMap(model.video(of:))
        ControlGroup {
            if let file {
                ShareLink(item: file) { Label("Stuur", systemImage: "square.and.arrow.up") }
                    .help("Stuur met AirDrop, Mail of Berichten")
            } else {
                Button {} label: { Label("Stuur", systemImage: "square.and.arrow.up") }
                    .disabled(true)
                    .help("Staat nog niet in iCloud Drive")
            }
            Button { if let video { ShrinkRequest.shared.open(video) } } label: {
                Label("Verklein", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(video == nil)
            .help("Verklein de video om te mailen of in te leveren")
            Button { reveal(id) } label: {
                Label("Toon in Finder", systemImage: "folder")
            }
            .disabled(id.flatMap(model.folder(of:)) == nil && file == nil)
            .help("Toon in Finder")
        }
        .controlGroupStyle(.navigation)
    }

    private func reveal(_ id: String?) {
        guard let id else { return }
        if let file = model.file(of: id) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if let folder = model.folder(of: id) {
            NSWorkspace.shared.open(folder)
        }
    }
}

/// Like Mail's filter: a click shows only the chosen labels or all again,
/// the menu picks which.
private struct LabelFilterButton: View {
    @Environment(PensieveModel.self) private var model
    @State private var chosen: Set<String> = []

    var body: some View {
        Menu {
            Section("Toon alleen") {
                ForEach(model.labels) { label in
                    Toggle(isOn: Binding(get: { model.labelFilter.contains(label.name) }, set: { on in
                        if on { model.labelFilter.insert(label.name) } else { model.labelFilter.remove(label.name) }
                    })) {
                        Text("\(label.name) (\(label.count))")
                    }
                }
                if model.labels.isEmpty { Text("Nog geen labels") }
            }
            Divider()
            SettingsLink { Text("Labels beheren…") }
        } label: {
            Label("Labels", systemImage: model.labelFilter.isEmpty ? "tag" : "tag.fill")
        } primaryAction: {
            if model.labelFilter.isEmpty {
                model.labelFilter = chosen
            } else {
                chosen = model.labelFilter
                model.labelFilter = []
            }
        }
        .help(model.labelFilter.isEmpty ? "Toon alleen een label" : "Toon weer alle labels")
    }
}

// MARK: List

struct RecordingList: View {
    @Environment(PensieveModel.self) private var model
    @State private var renaming: RecordingSummary?
    @State private var newTitle = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedId) {
            // No day sections: with them macOS 26 gives every row one line's height.
            ForEach(model.recordings) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
                    .contextMenu {
                        RecordingMenu(recording: recording) {
                            newTitle = recording.title
                            renaming = recording
                        }
                    }
            }
        }
        .listStyle(.inset)
        .alert("Titel", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titel", text: $newTitle)
            Button("Bewaar") { if let id = renaming?.id { Task { await model.rename(id, to: newTitle) } } }
            Button("Annuleer", role: .cancel) {}
        }
        .overlay {
            if model.recordings.isEmpty {
                if model.query.isEmpty {
                    ContentUnavailableView("Nog geen opnames", systemImage: "waveform", description: Text("Druk op de rode knop (⌘N) om op te nemen."))
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }

    private var title: String {
        if !model.query.isEmpty { return "Zoeken" }
        return model.kindFilter?.plural ?? "Alle opnames"
    }

    private var subtitle: String {
        let count = model.recordings.count
        let waiting = model.recordings.filter { $0.status == .stored && !$0.hasTranscript }.count
        var parts = [count == 1 ? "1 opname" : "\(count) opnames"]
        if waiting > 0 { parts.append("\(waiting) zonder transcript") }
        if !model.labelFilter.isEmpty { parts.append(model.labelFilter.sorted().joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

struct RecordingRow: View {
    @Environment(PensieveModel.self) private var model
    let recording: RecordingSummary

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Thumbnail(recording: recording, video: recording.kind.hasVideo ? model.video(of: recording.id) : nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recording.title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(listDate(recording.startedAt)).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Image(systemName: recording.kind.symbol).imageScale(.small)
                    Text(([recording.durationSeconds.map(clock)] + [recording.labels.isEmpty ? nil : recording.labels.joined(separator: ", ")])
                        .compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    RowStatus(recording: recording)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// What still runs for a row, or what it waits for.
private struct RowStatus: View {
    @Environment(PensieveModel.self) private var model
    let recording: RecordingSummary

    var body: some View {
        switch recording.status {
        case .failed:
            Text("Mislukt").foregroundStyle(BurrowColor.danger)
        case .compressing, .transcribing, .writingNotes:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(StatusPill.label(recording.status.rawValue))
            }
        case .stored where !recording.hasTranscript && recording.mine:
            Button { Task { await model.requestTranscript(recording.id) } } label: {
                Label("Transcript", systemImage: "doc.text").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .help("Maak het transcript en de samenvatting; alleen het geluid gaat naar Dobby")
        default:
            EmptyView()
        }
    }
}

/// The row's context menu: the same actions as the toolbar and the detail.
struct RecordingMenu: View {
    @Environment(PensieveModel.self) private var model
    let recording: RecordingSummary
    let rename: () -> Void

    var body: some View {
        if let file = model.file(of: recording.id) {
            ShareLink(item: file) { Label("Stuur…", systemImage: "square.and.arrow.up") }
            Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        if let video = model.video(of: recording.id) {
            Button("Verklein…") { ShrinkRequest.shared.open(video) }
        }
        if recording.mine {
            Divider()
            Button("Wijzig titel…", action: rename)
            Button("Bedenk een titel") { Task { await model.redo(recording.id, step: "title") } }
                .disabled(!recording.hasTranscript && !recording.hasNotes)
            if recording.status == .stored && !recording.hasTranscript {
                Button("Maak transcript") { Task { await model.requestTranscript(recording.id) } }
            } else {
                Button("Transcribeer opnieuw") { Task { await model.redo(recording.id, step: "transcript") } }
                if recording.kind != .dictation {
                    Button("Schrijf samenvatting opnieuw") { Task { await model.redo(recording.id, step: "notes") } }
                        .disabled(!recording.hasTranscript)
                }
            }
            Divider()
            Button("Verwijder…", role: .destructive) { confirmDelete(recording, model: model) }
        }
    }
}

@MainActor
func confirmDelete(_ recording: RecordingSummary, model: PensieveModel) {
    let alert = NSAlert()
    alert.messageText = "‘\(recording.title)’ verwijderen?"
    alert.informativeText = "Het geluid, het transcript en de samenvatting verdwijnen van Dobby. De map in iCloud Drive blijft staan."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Annuleer")
    alert.addButton(withTitle: "Verwijder")
    if alert.runModal() == .alertSecondButtonReturn {
        Task { await model.delete(recording.id) }
    }
}

/// A frame of the video, or the kind's symbol on a tile.
struct Thumbnail: View {
    let recording: RecordingSummary
    let video: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: recording.kind == .call ? "waveform" : recording.kind.symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: video) {
            if let video { image = await Thumbnails.shared.image(video) }
        }
    }
}

@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [URL: NSImage] = [:]

    func image(_ url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        guard let frame = try? await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600)).image else { return nil }
        let image = NSImage(cgImage: frame, size: .zero)
        cache[url] = image
        return image
    }
}

// MARK: Formatting

extension RecordingKind {
    static let lastKey = "pensieve.lastKind"
    static let recordable: [RecordingKind] = [.call, .video, .screen]

    var title: String { RecordingDefaults.name(of: self) }

    var plural: String {
        switch self {
        case .call: "Gesprekken"
        case .video: "Video"
        case .screen: "Scherm"
        case .dictation: "Dictaten"
        }
    }

    var symbol: String {
        switch self {
        case .call: "headphones"
        case .video: "video"
        case .screen: "display"
        case .dictation: "text.quote"
        }
    }
}

/// "14:05" today, else "do 16 okt", or with the year when not this year.
func listDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    let format = DateFormatter()
    format.locale = Locale(identifier: "nl_NL")
    format.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEE d MMM" : "d MMM yyyy"
    return format.string(from: date).replacingOccurrences(of: ".", with: "")
}

func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
