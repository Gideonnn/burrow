import HedwigCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: MailboxSummary?
    @State private var newName = ""

    var body: some View {
        // The list may clear its selection (a click beside a row, a rebuilt
        // list); the window would then show every mail under a stale
        // highlight, so a place is only ever replaced by another place.
        List(selection: Binding(get: { model.selection }, set: { if let place = $0 { model.selection = place } })) {
            ForEach(model.mailboxGroups) { group in
                Section(roleTitle(group.role)) {
                    if group.mailboxes.count > 1 {
                        NavigationLink(value: SidebarItem.role(group.role)) {
                            Label("Alle \(roleTitle(group.role).lowercased())", systemImage: "tray.2")
                        }
                        .badge(group.mailboxes.reduce(0) { $0 + (model.unreadCounts[$1.id] ?? 0) })
                        .tag(SidebarItem.role(group.role))
                    }
                    ForEach(group.mailboxes) { box in
                        NavigationLink(value: SidebarItem.inbox(mailboxId: box.id)) {
                            Label(mailboxTitle(box), systemImage: "tray")
                        }
                        .help(box.address)
                        .badge(model.unreadCounts[box.id] ?? 0)
                        .contextMenu {
                            let index = group.mailboxes.firstIndex(of: box) ?? 0
                            Button("Wijzig naam…") {
                                newName = mailboxTitle(box)
                                renaming = box
                            }
                            .disabled(!canOrganize)
                            Button("Omhoog") { move(group.role, index, to: index - 1) }
                                .disabled(!canOrganize || index == 0)
                            Button("Omlaag") { move(group.role, index, to: index + 2) }
                                .disabled(!canOrganize || index == group.mailboxes.count - 1)
                        }
                        // ForEach tags rows with the mailbox id; the list selects SidebarItems.
                        .tag(SidebarItem.inbox(mailboxId: box.id))
                    }
                    .onMove(perform: canOrganize ? { source, destination in
                        Task { await model.moveMailboxes(in: group.role, from: source, to: destination) }
                    } : nil)
                }
            }
            Section("Overal") {
                NavigationLink(value: SidebarItem.filtered) {
                    Label("Gefilterd", systemImage: "checkmark.shield")
                }
                .badge(model.filtered.count)
                NavigationLink(value: SidebarItem.outings) {
                    Label("Evenementen", systemImage: "ticket")
                }
                .badge(model.outingsBadge)
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
        .alert("Naam van de mailbox", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Naam", text: $newName)
            Button("Bewaar") { if let box = renaming { rename(box) } }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(renaming.map { "\($0.address). Laat leeg om de naam van de provider te tonen." } ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UpdateBanner()
                ConnectionBadge()
            }
        }
    }

    private var canOrganize: Bool { model.me?.can(.organize) == true }

    private func move(_ role: MailboxRole, _ index: Int, to destination: Int) {
        Task { await model.moveMailboxes(in: role, from: [index], to: destination) }
    }

    private func rename(_ box: MailboxSummary) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        // The address as name means "no name of its own": the sidebar then shows the provider.
        Task {
            do {
                try await model.updateMailbox(box.id, name: name.isEmpty ? box.address : name)
            } catch {
                model.error = error.localizedDescription
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

func roleTitle(_ role: MailboxRole) -> String {
    switch role {
    case .private: "Privé"
    case .work: "Werk"
    case .school: "School"
    }
}

/// The name the person gave the mailbox, or the provider while it is still the address.
func mailboxTitle(_ box: MailboxSummary) -> String {
    box.name == box.address ? providerName(box) : box.name
}

func providerName(_ box: MailboxSummary) -> String {
    switch box.provider {
    case .gmail: "Gmail"
    case .microsoft: "Outlook"
    case .fastmail: "Fastmail"
    }
}
