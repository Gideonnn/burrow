import HedwigCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Inboxen") {
                ForEach(model.me?.mailboxes ?? []) { box in
                    NavigationLink(value: SidebarItem.inbox(mailboxId: box.id)) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(providerName(box))
                                Text(box.address).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tray")
                        }
                    }
                    .badge(model.unreadCounts[box.id] ?? 0)
                    // ForEach tags rows with the mailbox id; the list selects SidebarItems.
                    .tag(SidebarItem.inbox(mailboxId: box.id))
                }
            }
            Section("Overal") {
                NavigationLink(value: SidebarItem.filtered) {
                    Label("Gefilterd", systemImage: "checkmark.shield")
                }
                .badge(model.filtered.count)
                NavigationLink(value: SidebarItem.tasks) {
                    Label("Taken", systemImage: "checklist")
                }
                .badge(model.tasksAwaitingReview)
                NavigationLink(value: SidebarItem.drafts) {
                    Label("Concepten", systemImage: "doc")
                }
                .badge(model.drafts.count)
                NavigationLink(value: SidebarItem.folder(.sent)) {
                    Label("Verstuurd", systemImage: "paperplane")
                }
                NavigationLink(value: SidebarItem.folder(.archive)) {
                    Label("Archief", systemImage: "archivebox")
                }
                NavigationLink(value: SidebarItem.folder(.spam)) {
                    Label("Spam", systemImage: "xmark.bin")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UpdateBanner()
                ConnectionBadge()
            }
        }
    }

}

struct UpdateBanner: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        if let version = updater.ready {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("Update klaar").font(.caption.weight(.semibold))
                Spacer()
                Button("Herstart") { (NSApp.delegate as? AppDelegate)?.restart() }
                    .controlSize(.small)
            }
            .help("Build \(version) staat klaar; Hedwig start opnieuw op met de nieuwe versie.")
            .padding(10)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 8)
        }
    }
}

struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.green).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.connection?.serverURL.host() ?? "").font(.caption.weight(.semibold))
                Text(model.me?.key.name ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.mini) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .padding(8)
    }
}

func providerName(_ box: MailboxSummary) -> String {
    switch box.provider {
    case .gmail: "Gmail"
    case .microsoft: "Outlook"
    case .fastmail: "Fastmail"
    }
}
