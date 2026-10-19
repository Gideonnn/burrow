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
                switch model.selection {
                case .filtered: FilteredListView()
                case .drafts: DraftListView()
                case .tasks: TaskListView()
                default: MessageListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            switch model.selection {
            case .filtered: FilteredDetailView()
            case .drafts: DraftDetailView()
            case .tasks: TaskDetailView()
            default: MessageDetailView()
            }
        }
        .toolbar { MainToolbar() }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var showsMail: Bool {
        switch model.selection {
        case .filtered, .drafts, .tasks: false
        default: true
        }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { if let d = model.newMessage() { openWindow(value: d) } } label: {
                Label("Nieuw bericht", systemImage: "square.and.pencil")
            }
            .help("Nieuw bericht (⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if showsMail {
            ControlGroup {
                Button { if let d = model.reply() { openWindow(value: d) } } label: {
                    Label("Antwoord", systemImage: "arrowshape.turn.up.left")
                }
                Button { if let d = model.reply(all: true) { openWindow(value: d) } } label: {
                    Label("Allen antwoorden", systemImage: "arrowshape.turn.up.left.2")
                }
                Button { if let d = model.forward() { openWindow(value: d) } } label: {
                    Label("Stuur door", systemImage: "arrowshape.turn.up.right")
                }
            }
            .disabled(model.detail == nil || model.me?.can(.send) != true)

            ControlGroup {
                Button { Task { await model.perform([.archive]) } } label: {
                    Label("Archiveer", systemImage: "archivebox")
                }
                Button { Task { await model.perform([.trash]) } } label: {
                    Label("Verwijder", systemImage: "trash")
                }
                Button { Task { await model.perform([.moveToSpam, .markRead]) } } label: {
                    Label("Spam", systemImage: "xmark.bin")
                }
            }
            .disabled(model.detail == nil || model.me?.can(.organize) != true)

            Button { Task { await model.toggleFlag() } } label: {
                Label("Vlag", systemImage: model.currentSummary?.flagged == true ? "flag.fill" : "flag")
            }
            .disabled(model.detail == nil || model.me?.can(.organize) != true)
            }
        }
    }
}
