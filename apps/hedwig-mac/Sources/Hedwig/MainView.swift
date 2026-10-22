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
        } detail: {
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
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Zoek")
        .onSubmit(of: .search) { Task { await model.searchWithAI() } }
        .modifier(SearchFocus(request: model.searchFocusRequest))
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

    // Three glass capsules like Apple Mail, at Mail's size: compose on its own, then the reply
    // trio, then archive, delete and spam. macOS 26 merges neighbouring toolbar
    // items into one glass, also across ToolbarSpacer here, so each item hides
    // the shared background and draws its own. Flagging is in the menu (⇧⌘L).
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) {
                compose.frame(width: 36, height: 36).glassEffect(.regular.interactive(), in: .circle)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                replies.frame(height: 36).glassEffect(.regular.interactive(), in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                organizing.frame(height: 36).glassEffect(.regular.interactive(), in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
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
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .help("Nieuw bericht (⌘N)")
    }

    private var replies: some View {
        ToolbarCapsule {
            Button { if let d = model.reply() { openWindow(value: d) } } label: {
                Label("Antwoord", systemImage: "arrowshape.turn.up.left")
            }
            .help("Antwoord (⌘R)")
            Divider()
            Button { if let d = model.reply(all: true) { openWindow(value: d) } } label: {
                Label("Allen antwoorden", systemImage: "arrowshape.turn.up.left.2")
            }
            .help("Allen antwoorden (⇧⌘R)")
            Divider()
            Button { if let d = model.forward() { openWindow(value: d) } } label: {
                Label("Stuur door", systemImage: "arrowshape.turn.up.right")
            }
            .help("Stuur door (⇧⌘F)")
        }
        .disabled(!canReply)
    }

    private var organizing: some View {
        ToolbarCapsule {
            Button { Task { await model.perform([.archive]) } } label: {
                Label("Archiveer", systemImage: "archivebox")
            }
            .help("Archiveer (⌃⌘A)")
            Divider()
            Button { Task { await model.perform([.trash]) } } label: {
                Label("Verwijder", systemImage: "trash")
            }
            .accessibilityIdentifier("hedwig.trash")
            .help("Verwijder (⌘⌫)")
            Divider()
            Button { Task { await model.perform([.moveToSpam]) } } label: {
                Label("Spam", systemImage: "xmark.bin")
            }
            .help("Markeer als spam (⇧⌘J)")
        }
        .disabled(!canOrganize)
    }

    private var canReply: Bool { showsMail && model.detail != nil && model.me?.can(.send) == true }
    private var canOrganize: Bool { showsMail && model.detail != nil && model.me?.can(.organize) == true }
}

/// Icon buttons side by side with thin dividers, inside one toolbar item.
private struct ToolbarCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .imageScale(.large)
            .fixedSize()
            .padding(.horizontal, 10)
    }
}
