import HedwigCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            Group {
                if model.isSearching {
                    MessageListView()
                } else {
                    switch model.selection {
                    case .drafts: DraftListView()
                    case .tasks: TaskListView()
                    case .outings: OutingListView()
                    default: MessageListView()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
            // A toolbar item in this column also makes SwiftUI track the divider to the
            // reading column, so MainToolbar starts at that column's leading edge like Mail.
            .toolbar {
                if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
                ToolbarItem { ListFilterButton() }
            }
        } detail: {
            Group {
                if model.isSearching {
                    MessageDetailView()
                } else {
                    switch model.selection {
                    case .drafts: DraftDetailView()
                    case .tasks: TaskDetailView()
                    case .outings: OutingDetailView()
                    default: MessageDetailView()
                    }
                }
            }
            .toolbar { MainToolbar() }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Zoek")
        .onSubmit(of: .search) { Task { await model.searchWithAI() } }
        .modifier(SearchFocus(request: model.searchFocusRequest))
    }
}

/// Like Mail's: a click turns the filter on or off, the menu picks what it filters on.
private struct ListFilterButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Section("Filter op") {
                ForEach(ListFilter.allCases, id: \.self) { criterion in
                    Toggle(isOn: Binding(get: { model.filterCriteria.contains(criterion) }, set: { _ in model.toggle(criterion) })) {
                        Label(criterion.title, systemImage: criterion.systemImage)
                    }
                }
            }
        } label: {
            // The toolbar draws menu icons as templates, so the filled symbol is the highlight.
            Label("Filter", systemImage: model.filterOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        } primaryAction: {
            model.filterOn.toggle()
        }
        .help(model.filterOn ? "Zet het filter uit (⌘L)" : "Filter de lijst (⌘L)")
        .disabled(model.placeScope == nil || model.isSearching)
    }
}

/// ⌘F puts the cursor in the search field.
private struct SearchFocus: ViewModifier {
    let request: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .searchFocused($focused)
                .onChange(of: request) { focused = true }
        } else {
            content
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var showsMail: Bool {
        if model.isSearching { return true }
        return switch model.selection {
        case .drafts, .tasks, .outings: false
        default: true
        }
    }

    // Compose at the leading edge of the reading column, the reply and organize groups
    // between it and the search field (SwiftUI puts a flexible space before search).
    // Flagging is in the menu (⇧⌘L).
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem { compose }
            ToolbarSpacer(.flexible)
            ToolbarItem { replies }
            ToolbarSpacer(.fixed)
            ToolbarItem { organizing }
        } else {
            ToolbarItem(placement: .primaryAction) { compose }
            ToolbarItem(placement: .primaryAction) { replies }
            ToolbarItem(placement: .primaryAction) { organizing }
        }
    }

    private var compose: some View {
        Button { if let d = model.newMessage() { openWindow(value: d) } } label: {
            Label("Nieuw bericht", systemImage: "square.and.pencil")
        }
        .help("Nieuw bericht (⌘N)")
    }

    private var replies: some View {
        ControlGroup {
            Button { if let d = model.reply() { openWindow(value: d) } } label: {
                Label("Antwoord", systemImage: "arrowshape.turn.up.left")
            }
            .help("Antwoord (⌘R)")
            Button { if let d = model.reply(all: true) { openWindow(value: d) } } label: {
                Label("Allen antwoorden", systemImage: "arrowshape.turn.up.left.2")
            }
            .help("Allen antwoorden (⇧⌘R)")
            Button { if let d = model.forward() { openWindow(value: d) } } label: {
                Label("Stuur door", systemImage: "arrowshape.turn.up.right")
            }
            .help("Stuur door (⇧⌘F)")
        }
        .controlGroupStyle(.navigation)
        .disabled(!canReply)
    }

    private var organizing: some View {
        ControlGroup {
            Button { Task { await model.perform([.archive]) } } label: {
                Label("Archiveer", systemImage: "archivebox")
            }
            .help("Archiveer (⌃⌘A)")
            Button { Task { await model.perform([.trash]) } } label: {
                Label("Verwijder", systemImage: "trash")
            }
            .accessibilityIdentifier("hedwig.trash")
            .help("Verwijder (⌘⌫)")
            Button { Task { await model.perform([.moveToSpam]) } } label: {
                Label("Spam", systemImage: "xmark.bin")
            }
            .help("Markeer als spam (⇧⌘J)")
        }
        .controlGroupStyle(.navigation)
        .disabled(!canOrganize)
    }

    private var canReply: Bool { showsMail && model.detail != nil && model.me?.can(.send) == true }
    private var canOrganize: Bool { showsMail && model.detail != nil && model.me?.can(.organize) == true }
}
