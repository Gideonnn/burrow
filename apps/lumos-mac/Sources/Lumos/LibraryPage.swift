import BurrowUI
import Charts
import LumosCore
import LumosUI
import SwiftUI

/// What is on Dobby or on its way: the disk, one table for films and
/// series, Bezig with progress, and deleting with a question first.
struct LibraryPage: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.status?.requests != true {
                ContentUnavailableView(
                    "Bibliotheek werkt met Seerr", systemImage: "externaldrive.badge.xmark",
                    description: Text("De server heeft Seerr nodig om te zien wat er op Dobby staat."))
            } else if model.manageAnswer == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    DiskCard()
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    LibraryFilterBar()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    if model.shelf == .busy { BusyList() } else { LibraryTable() }
                }
            }
        }
        .inspector(isPresented: $model.libraryInspector) {
            LibraryInspector()
                .inspectorColumnWidth(min: 240, ideal: 290, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.canDelete {
                    Button("Verwijder van Dobby", systemImage: "trash") { model.askDelete() }
                        .disabled(!model.canDeleteTarget)
                        .help("Verwijder de selectie van Dobby (⌫)")
                }
                Button(model.libraryInspector ? "Verberg inspector" : "Toon inspector", systemImage: "sidebar.trailing") {
                    model.libraryInspector.toggle()
                }
                .help("Inspector (⌥⌘I)")
            }
        }
    }
}

/// The confirmation before files are wiped; Annuleer is the default.
struct DeleteDialog: ViewModifier {
    @Environment(LumosModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.confirmationDialog(
            model.deleteRequest?.question ?? "",
            isPresented: $model.deleteRequest.isPresent(),
            titleVisibility: .visible,
            presenting: model.deleteRequest
        ) { _ in
            Button("Verwijderen", role: .destructive) { Task { await model.confirmDelete() } }
            Button("Annuleer", role: .cancel) { model.deleteRequest = nil }
                .keyboardShortcut(.defaultAction)
        } message: { request in
            Text(request.message)
        }
    }
}

extension View {
    func deleteDialog() -> some View { modifier(DeleteDialog()) }
}

// MARK: The disk

/// Free of total, split like Storage in System Settings, with "Ruimte maken".
struct DiskCard: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let disk = model.disk {
                        Text("\(Bytes.text(disk.free)) vrij").font(.title2).bold().monospacedDigit()
                        Text("van \(Bytes.text(disk.total)) op Dobby").foregroundStyle(.secondary)
                    } else {
                        Text("Op Dobby").font(.title2).bold()
                        Text("Jellyfin zegt niet hoeveel ruimte er is").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.canDelete, !model.spaceCandidates.isEmpty {
                        let candidates = model.spaceCandidates
                        Text("\(candidates.count) grote titels samen gezien, \(Bytes.text(candidates.compactMap(\.sizeBytes).reduce(0, +)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Ruimte maken") { model.makeRoom() }
                            .buttonStyle(.bordered)
                            .help("Selecteert wat jullie samen gezien hebben, groter dan 25 GB en op geen lijst, grootste eerst")
                    }
                }
                if let disk = model.disk {
                    DiskChart(disk: disk)
                }
                if let next = model.manageAnswer?.busy.first(where: { $0.download != nil }), let download = next.download {
                    Text("Nu: \(next.title.title) \(Int((download.progress * 100).rounded())) %\(Eta.text(download.eta).map { ", \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }
}

struct DiskChart: View {
    let disk: DiskUse

    private var parts: [(name: String, bytes: Double)] {
        [("Films", disk.films), ("Series", disk.series), ("Overig", disk.other), ("Onderweg", disk.coming),
         ("Vrij", max(0, disk.free - disk.coming))]
    }

    var body: some View {
        Chart(parts, id: \.name) { part in
            BarMark(x: .value("Ruimte", part.bytes))
                .foregroundStyle(by: .value("Soort", "\(part.name) \(Bytes.text(part.bytes))"))
        }
        .chartForegroundStyleScale(
            domain: parts.map { "\($0.name) \(Bytes.text($0.bytes))" },
            range: [
                AnyShapeStyle(.tint), AnyShapeStyle(.tint.opacity(0.6)), AnyShapeStyle(.gray.opacity(0.6)),
                // Charts cannot resolve the hierarchical .quaternary, so free space is grey by hand.
                AnyShapeStyle(.tint.opacity(0.3)), AnyShapeStyle(Color.gray.opacity(0.25)),
            ])
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...max(disk.total, 1))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .frame(height: 54)
        .accessibilityLabel("Schijfgebruik")
        .accessibilityValue(parts.map { "\($0.name) \(Bytes.text($0.bytes))" }.joined(separator: ", "))
    }
}

enum Eta {
    /// "klaar rond 21:40", or with the day when it is not today.
    static func text(_ eta: String?) -> String? {
        guard let eta, let date = (try? Date(eta, strategy: .iso8601)) ?? fractional(eta) else { return nil }
        if Calendar.current.isDateInToday(date) { return "klaar rond \(date.formatted(date: .omitted, time: .shortened))" }
        return "klaar \(date.formatted(.dateTime.weekday(.wide).hour().minute()))"
    }

    private static func fractional(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

// MARK: Filters

struct LibraryFilterBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let library = model.manageAnswer?.library ?? []
        let films = library.filter { $0.title.mediaType == .movie }.count
        HStack(spacing: 10) {
            Picker("Soort", selection: $model.shelf) {
                Text("Alles \(library.count)").tag(LumosModel.Shelf.all)
                Text("Films \(films)").tag(LumosModel.Shelf.movie)
                Text("Series \(library.count - films)").tag(LumosModel.Shelf.tv)
                Text("Bezig \(model.busyCount)").tag(LumosModel.Shelf.busy)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if model.shelf != .busy {
                Picker("Gekeken", selection: $model.watchedFilter) {
                    ForEach(LumosModel.WatchedFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Spacer()
            if !model.canDelete {
                Text("Alleen een beheerder kan verwijderen").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: The table

struct LibraryTable: View {
    @Environment(LumosModel.self) private var model
    @SceneStorage("lumos.library.columns") private var columns = TableColumnCustomization<LibraryRow>()

    var body: some View {
        @Bindable var model = model
        let rows = model.libraryRows
        Table(of: LibraryRow.self, selection: $model.librarySelection, sortOrder: sortOrder, columnCustomization: $columns) {
            TableColumn("Titel", value: \.title) { row in TitleCell(item: row.item) }
                .width(min: 220, ideal: 340)
                .customizationID("title")
            TableColumn("Gekeken", value: \.watchedRank) { row in
                let watched = row.item.watched
                Label(watched.label, systemImage: watched.symbol)
                    .foregroundStyle(watched.kind == .none ? .secondary : .primary)
                    .symbolRenderingMode(.hierarchical)
            }
            .width(min: 120, ideal: 180)
            .customizationID("watched")
            TableColumn("Toegevoegd", value: \.added) { row in
                Text(row.item.added.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "–")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            .customizationID("added")
            TableColumn("Grootte", value: \.size) { row in
                Text(row.item.sizeBytes.map(Bytes.text) ?? "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            .alignment(.trailing)
            .customizationID("size")
        } rows: {
            ForEach(rows) { row in
                TableRow(row).draggable(row.id.description)
            }
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: TitleRef.self) { refs in
            if refs.count == 1, let ref = refs.first, let item = model.libraryItem(ref) {
                TitleContextMenu(title: item.title)
            } else if !refs.isEmpty, model.canDelete {
                Button("Verwijder \(refs.count) titels van Dobby…", role: .destructive) { model.askDelete(Array(refs)) }
            }
        } primaryAction: { refs in
            if refs.count == 1, let ref = refs.first { model.open(ref, focusInside: true) }
        }
        .onKeyPress(.escape) {
            model.escape()
            return .handled
        }
        .overlay {
            if rows.isEmpty {
                let text = model.query.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else {
                    ContentUnavailableView(
                        "Niets met dit filter", systemImage: "externaldrive",
                        description: Text(model.manageAnswer?.library.isEmpty == true ? "Er staat nog niets op Dobby." : "Kies een ander filter voor Gekeken."))
                }
            }
        }
    }

    private var sortOrder: Binding<[KeyPathComparator<LibraryRow>]> {
        Binding(get: {
            let order: SortOrder = model.librarySort.ascending ? .forward : .reverse
            switch model.librarySort.key {
            case .title: return [KeyPathComparator(\LibraryRow.title, order: order)]
            case .watched: return [KeyPathComparator(\LibraryRow.watchedRank, order: order)]
            case .added: return [KeyPathComparator(\LibraryRow.added, order: order)]
            case .size: return [KeyPathComparator(\LibraryRow.size, order: order)]
            }
        }, set: { comparators in
            guard let first = comparators.first else { return }
            let key: LibrarySort.Key =
                switch first.keyPath {
                case \LibraryRow.title: .title
                case \LibraryRow.watchedRank: .watched
                case \LibraryRow.size: .size
                default: .added
                }
            model.librarySort = LibrarySort(key: key, ascending: first.order == .forward)
        })
    }
}

/// The poster, the title with a lock when it was copied in by hand, and its facts.
struct TitleCell: View {
    @Environment(LumosModel.self) private var model
    let item: ManageItem

    var body: some View {
        HStack(spacing: 10) {
            Artwork(title: item.title, style: .poster)
                .frame(width: 28, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title.title).lineLimit(1)
                    if !item.removable {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(item.lockReason)
                            .accessibilityLabel("Met de hand gekopieerd")
                    }
                }
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var line: String {
        var parts = [item.title.kind, item.title.year.map(String.init), item.title.length].compactMap { $0 }
        if let picture = item.server?.media?.picture { parts.append(picture) }
        if item.title.onList { parts.append("op de lijst") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Bezig

/// Requested, waiting for a release, downloading with its end time, importing.
struct BusyList: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        let items = model.busyItems
        List(items) { item in
            BusyRow(item: item)
                .contextMenu { TitleContextMenu(title: item.title) }
                .onTapGesture(count: 2) { model.open(item.id, focusInside: true) }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Niets onderweg", systemImage: "arrow.down.circle", description: Text("Er wordt niets aangevraagd of gedownload."))
            }
        }
    }
}

struct BusyRow: View {
    @Environment(LumosModel.self) private var model
    let item: ManageItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(title: item.title, style: .poster)
                .frame(width: 32, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.title)
                Text([item.title.kind, item.title.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let download = item.download {
                    ProgressView(value: download.progress)
                        .accessibilityLabel("Gedownload")
                    Text(progressText(download)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.title.availability.label)
                    .foregroundStyle(item.title.availability == .importProblem ? .red : .primary)
                if let eta = Eta.text(item.download?.eta) {
                    Text(eta).font(.callout).foregroundStyle(.secondary)
                }
                if item.title.availability == .importProblem {
                    Button("Opnieuw proberen") { Task { await model.retryRequest(item.id) } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func progressText(_ download: Download) -> String {
        let percent = "\(Int((download.progress * 100).rounded())) %"
        guard let left = download.bytesLeft, download.progress < 1 else { return percent }
        let total = left / max(0.0001, 1 - download.progress)
        return "\(percent) · \(Bytes.text(total - left)) van \(Bytes.text(total))"
    }
}

// MARK: The inspector

struct LibraryInspector: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        let selected = model.selectedItems
        Group {
            if selected.isEmpty {
                ContentUnavailableView("Geen selectie", systemImage: "sidebar.trailing", description: Text("Kies een titel in de tabel."))
            } else if selected.count == 1 {
                OneTitle(item: selected[0])
            } else {
                SeveralTitles(items: selected)
            }
        }
    }
}

private struct OneTitle: View {
    @Environment(LumosModel.self) private var model
    let item: ManageItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Artwork(title: item.title, style: .wide)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.title).font(.title2).bold()
                    Text(item.title.line).foregroundStyle(.secondary)
                }
                HStack {
                    if model.canWatch {
                        Button("Kijken", systemImage: "play.fill") { Task { await model.watch(item.id) } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Details") { model.open(item.id, focusInside: true) }
                        .buttonStyle(.bordered)
                }
                OnDobbyFacts(item: item)
                if model.canDelete {
                    Button("Verwijderen…", systemImage: "trash", role: .destructive) { model.askDelete([item.id]) }
                        .disabled(!item.removable)
                    if !item.removable {
                        Label(item.lockReason, systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }
}

/// Size, added, seen together and by you, the picture and sound, who manages it.
struct OnDobbyFacts: View {
    @Environment(LumosModel.self) private var model
    let item: ManageItem

    var body: some View {
        Form {
            LabeledContent("Grootte", value: item.sizeBytes.map(Bytes.text) ?? "Onbekend")
            if let added = item.added {
                LabeledContent("Toegevoegd", value: added.formatted(.dateTime.day().month(.wide).year()))
            }
            LabeledContent("Samen", value: together)
            LabeledContent(model.myName, value: item.seen?.me == true ? "Al gezien" : "Nog niet")
            if let media = item.server?.media {
                if let picture = media.picture { LabeledContent("Beeld", value: picture) }
                if !media.audio.isEmpty { LabeledContent("Audio", value: media.audio.joined(separator: ", ")) }
                if !media.subtitles.isEmpty { LabeledContent("Ondertitels", value: media.subtitles.joined(separator: ", ")) }
            }
            LabeledContent("Beheerd door", value: item.managedBy)
        }
        .formStyle(.columns)
    }

    /// What the household's Jellyfin account says, or Lumos's own "Al gezien".
    private var together: String {
        if let watched = item.server?.watched {
            if watched.played {
                return watched.playCount > 1 ? "Gezien, \(watched.playCount) keer" : "Gezien"
            }
            if let resume = watched.resume, resume.positionSeconds > 0 || resume.episode != nil { return "Bezig: \(resume.label)" }
            if let done = watched.episodesPlayed, let total = watched.episodes, done > 0 { return "\(done) van \(total) afleveringen" }
        }
        return item.seen?.together == true ? "Al gezien" : "Nog niet"
    }
}

private struct SeveralTitles: View {
    @Environment(LumosModel.self) private var model
    let items: [ManageItem]

    var body: some View {
        let removable = items.filter(\.removable)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(items.count) titels").font(.title2).bold()
                Text("geselecteerd").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Samen", value: Bytes.text(items.compactMap(\.sizeBytes).reduce(0, +)))
                LabeledContent("Samen gezien", value: "\(items.filter { $0.watched.kind == .together }.count) van \(items.count)")
                if model.canDelete, removable.count < items.count {
                    LabeledContent("Blijft staan", value: "\(items.count - removable.count), met de hand gekopieerd")
                }
            }
            if model.canDelete {
                Button("Verwijderen…", systemImage: "trash", role: .destructive) { model.askDelete(items.map(\.id)) }
                    .disabled(removable.isEmpty)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
