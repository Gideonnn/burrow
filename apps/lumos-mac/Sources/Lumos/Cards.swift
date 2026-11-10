import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// A poster or a still with its title: large artwork, system chrome. A
/// click opens the title; the keyboard cursor draws the focus ring; the
/// actions are in the context menu and the Titel menu. Drag it onto the
/// list in the sidebar.
struct CardView: View {
    @Environment(LumosModel.self) private var model
    let title: TitleSummary
    let card: CardID
    let style: TitleRow.Style

    private var size: CGSize {
        style == .wide ? CGSize(width: 300, height: 168.75) : CGSize(width: 150, height: 225)
    }

    private var isCursor: Bool { model.cursor == card && model.focus == .content }

    var body: some View {
        Button {
            model.select(card)
            model.open(title.ref, from: card, focusInside: false)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(title: title, style: style)
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .topLeading) { state }
                    .overlay(alignment: .topTrailing) { listMark }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(title.pass == nil || model.page == .list ? 1 : 0.55)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.tint, lineWidth: 3)
                            .padding(-4)
                            .opacity(isCursor ? 1 : 0)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.title).font(.callout).lineLimit(1)
                    Text(title.match ?? title.line)
                        .font(.caption)
                        .foregroundStyle(title.match == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .lineLimit(1)
                }
            }
            .frame(width: size.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .id(card.description)
        .onHover { inside in if inside { model.prefetch(title.ref) } }
        .contextMenu { TitleContextMenu(title: title, card: card) }
        .draggable(title.ref.description) {
            Artwork(title: title, style: .poster).frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .popover(isPresented: Binding(
            get: { model.reasonMenu == title.ref && model.cursor == card && model.focus != .inspector },
            set: { if !$0 { model.reasonMenu = nil } }
        ), arrowEdge: .bottom) {
            ReasonMenu(ref: title.ref)
        }
        .accessibilityLabel(accessibilityText)
    }

    private var holding: ManageItem? { model.libraryItem(title.ref) }

    /// "Op Dobby · gezien", "62 %", "Wacht op release".
    private var stateText: String? {
        if let item = holding, let download = item.download { return "\(Int((download.progress * 100).rounded())) %" }
        switch title.availability {
        case .available, .partiallyAvailable:
            return holding?.watched.kind == .together ? "Op Dobby · gezien" : "Op Dobby"
        case .notRequested: return nil
        default: return title.availability.label
        }
    }

    @ViewBuilder private var state: some View {
        if let text = stateText {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
    }

    @ViewBuilder private var listMark: some View {
        if title.onList {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .padding(8)
                .accessibilityHidden(true)
        }
    }

    /// "Zout Water, film, op Dobby, samen gezien, op de lijst".
    private var accessibilityText: String {
        var parts = [title.title, title.kind.lowercased()]
        if let year = title.year { parts.append(String(year)) }
        if let text = stateText { parts.append(text.lowercased().replacingOccurrences(of: " · gezien", with: ", samen gezien")) }
        if title.onList { parts.append("op \(model.listName.lowercased())") }
        if let pass = title.pass { parts.append(pass.kind == .seen ? "al gezien" : "overgeslagen") }
        if let match = title.match { parts.append(match) }
        return parts.joined(separator: ", ")
    }
}

/// Right-click on a poster, and the same for a table row.
struct TitleContextMenu: View {
    @Environment(LumosModel.self) private var model
    let title: TitleSummary
    var card: CardID?

    var body: some View {
        let list = model.listName.lowercased()
        Button("Toon details") {
            if let card { model.select(card) }
            model.open(title.ref, from: card, focusInside: true)
        }
        Divider()
        Button(title.onList ? "Haal van \(list)" : "Zet op \(list)") { Task { await model.toggleList(title.ref) } }
            .accessibilityIdentifier("lumos.approve.list")
        Menu("Niet nu") {
            Button("Zonder reden") { Task { await model.notNow(title.ref) } }
            ForEach(LumosModel.passReasons, id: \.self) { reason in
                Button(reason) { Task { await model.notNow(title.ref, reason: reason) } }
            }
        }
        Button("Al gezien") { Task { await model.seen(title.ref) } }
        Divider()
        if title.hasTrailer {
            Button("Speel trailer af") {
                if let card { model.select(card) }
                Task { await model.playTrailer(title.ref) }
            }
        }
        if title.availability.held, model.canWatch {
            Button("Kijk op de tv") { Task { await model.watch(title.ref) } }
        }
        if let url = TitleLinks.tmdb(title) {
            ShareLink("Deel…", item: url, subject: Text(title.title))
        }
        if model.canDelete, let item = model.manageAnswer?.library.first(where: { $0.id == title.ref }) {
            Divider()
            Button("Verwijder van Dobby…", role: .destructive) {
                let refs = model.page == .library && model.librarySelection.contains(title.ref) ? Array(model.librarySelection) : [title.ref]
                model.askDelete(refs)
            }
            .disabled(!item.removable)
        }
    }
}

enum TitleLinks {
    /// TMDB's page, for sharing; the fixtures have none.
    static func tmdb(_ title: TitleSummary) -> URL? {
        guard title.tmdbId < 9_000_000 else { return nil }
        return URL(string: "https://www.themoviedb.org/\(title.mediaType.rawValue)/\(title.tmdbId)")
    }
}

/// "Niet nu" with an optional reason: Enter takes none, arrows pick one.
/// The keys stay with the page; the model holds the choice.
struct ReasonMenu: View {
    @Environment(LumosModel.self) private var model
    let ref: TitleRef

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Niet nu, reden is optioneel").font(.headline)
            Picker("Reden", selection: Binding(
                get: { model.reasonChoice },
                set: { index in Task { await model.chooseReason(index) } }
            )) {
                ForEach(Array(LumosModel.reasonOptions.enumerated()), id: \.offset) { index, option in
                    Text(option).tag(index)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Pijlen kiezen, Enter bevestigt").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }
}
