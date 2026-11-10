import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// Ontdekken and the list: rows or a grid of posters, driven by the
/// keyboard through the model. J, N, T, K and V are menu commands; this
/// view only moves, opens and closes.
struct CardPage: View {
    @Environment(LumosModel.self) private var model
    var focused: FocusState<LumosModel.Focus?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            if model.page == .discover {
                FilterBar()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            if let empty {
                empty
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            if !model.searchCredits.isEmpty { CreditsBar() }
                            ForEach(model.rows) { row in
                                if row.grid { GridSection(row: row) } else { Shelf(row: row) }
                            }
                            if model.loadingMore {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                    .focusable()
                    .focused(focused, equals: .content)
                    .focusEffectDisabled()
                    .onExitCommand { model.escape() }
                    .onKeyPress(phases: .down) { press in handle(press) }
                    .onChange(of: model.cursor) {
                        guard let cursor = model.cursor else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(cursor.description) }
                    }
                }
            }
        }
    }

    /// The system's empty states: no results, nothing with these filters, an empty list.
    private var empty: AnyView? {
        let items = model.rows.reduce(0) { $0 + $1.items.count }
        guard items == 0, !model.isLoading else { return nil }
        let text = model.query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return AnyView(ContentUnavailableView.search(text: text)) }
        if model.page == .list {
            return AnyView(ContentUnavailableView(
                "Nog niets op de lijst", systemImage: "bookmark",
                description: Text("Druk J op een titel of sleep een poster naar \(model.listName.lowercased()) in de zijbalk.")))
        }
        if !model.filter.plain {
            return AnyView(ContentUnavailableView(
                "Niets met deze filters", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Kies een ander genre of decennium.")))
        }
        return nil
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) || press.modifiers.contains(.option) {
            return .ignored
        }
        if model.reasonMenu != nil {
            switch press.key {
            case .downArrow: model.moveReason(by: 1)
            case .upArrow: model.moveReason(by: -1)
            case .return: Task { await model.chooseReason() }
            case .escape: model.reasonMenu = nil
            default: return .ignored
            }
            return .handled
        }
        switch press.key {
        case .leftArrow: model.move(.left)
        case .rightArrow: model.move(.right)
        case .upArrow: model.move(.up)
        case .downArrow: model.move(.down)
        case .home: model.move(.home)
        case .end: model.move(.end)
        case .space: model.toggleInspector()
        case .return:
            guard let cursor = model.cursor else { return .ignored }
            model.open(cursor.ref, from: cursor, focusInside: true)
        case .escape: model.escape()
        default:
            switch press.characters.lowercased() {
            case "z": Task { await model.undo() }
            case "/": model.requestSearchFocus()
            default: return .ignored
            }
        }
        return .handled
    }
}

/// Alles, Films or Series, then Sorteer, Genre (with the moods first),
/// Decennium, Nederlands and Verras me.
struct FilterBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Picker("Soort", selection: binding(\.kind)) {
                ForEach(LumosModel.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Sorteer", selection: binding(\.sort)) {
                ForEach(LumosModel.Sort.allCases, id: \.self) { Text(model.sortLabel($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Picker("Genre", selection: binding(\.genre)) {
                Text("Alle genres").tag(LumosModel.GenreChoice?.none)
                Section("Stemming") {
                    ForEach(LumosModel.Mood.allCases, id: \.self) { Text($0.rawValue).tag(LumosModel.GenreChoice?.some(.mood($0))) }
                }
                if !model.genreNames.isEmpty {
                    Section("Genre") {
                        ForEach(model.genreNames, id: \.self) { Text($0).tag(LumosModel.GenreChoice?.some(.genre($0))) }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Picker("Decennium", selection: binding(\.decade)) {
                Text("Alle jaren").tag(Int?.none)
                ForEach(Array(stride(from: 2020, through: 1950, by: -10)), id: \.self) { decade in
                    Text("Jaren \(String(decade).suffix(2))").tag(Int?.some(decade))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Toggle("Nederlands", isOn: binding(\.dutch))
                .toggleStyle(.button)
                .help("Alleen Nederlandstalige producties")
            Spacer(minLength: 0)
            Button("Verras me", systemImage: "dice") { Task { await model.surprise() } }
                .buttonStyle(.bordered)
                .help("Nieuwe rijen, zonder filters (V)")
        }
        .controlSize(.regular)
    }

    private func binding<Value>(_ path: WritableKeyPath<LumosModel.Filter, Value>) -> Binding<Value> {
        Binding(get: { model.filter[keyPath: path] }, set: { value in
            Task { await model.setFilter { $0[keyPath: path] = value } }
        })
    }
}

struct CreditsBar: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text("Makers en cast").font(.callout).foregroundStyle(.secondary)
            ForEach(model.searchCredits, id: \.id) { credit in
                Button(credit.name) { model.openPerson(credit.id, name: credit.name) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Alles van \(credit.name)")
            }
        }
        .padding(.horizontal, 24)
    }
}

struct RowHeader: View {
    let row: TitleRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.title).font(.title3).bold()
            if let subtitle = row.subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One horizontal row of stills or posters.
struct Shelf: View {
    let row: TitleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !row.title.isEmpty { RowHeader(row: row) }
            if row.items.isEmpty, let empty = row.empty {
                Text(empty).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(row.items) { title in
                            CardView(title: title, card: CardID(row: row.key, ref: title.ref), style: row.style)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// A page of posters in lines; the model learns how many fit in a line,
/// and the grid's last lines ask for the next page.
struct GridSection: View {
    @Environment(LumosModel.self) private var model
    let row: TitleRow
    @State private var columns = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !row.title.isEmpty { RowHeader(row: row) }
            if row.items.isEmpty, let empty = row.empty {
                Text(empty).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(row.style.cardWidth), spacing: 16, alignment: .top), count: columns),
                    alignment: .leading, spacing: 22
                ) {
                    ForEach(Array(row.items.enumerated()), id: \.element.id) { index, title in
                        CardView(title: title, card: CardID(row: row.key, ref: title.ref), style: row.style)
                            .onAppear {
                                if row.key == "grid", index >= row.items.count - columns * 2 { Task { await model.loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { fit(geometry.size.width) }
                    .onChange(of: geometry.size.width) { fit(geometry.size.width) }
            }
        }
    }

    private func fit(_ width: CGFloat) {
        let next = max(1, Int((width - 48 + 16) / row.style.cardStep))
        columns = next
        model.setColumns(next, for: row.key)
    }
}
