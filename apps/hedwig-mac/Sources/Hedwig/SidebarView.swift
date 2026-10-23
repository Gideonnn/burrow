import BurrowUI
import HedwigCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: MailboxSummary?
    @State private var newName = ""
    @State private var hovered: String?
    // The mailboxes whose folders show, as comma-separated ids: AppStorage holds no sets.
    @AppStorage("hedwig.sidebar.openMailboxes") private var openMailboxes = ""

    var body: some View {
        // The list may clear its selection (a click beside a row, a rebuilt
        // list); the window would then show every mail under a stale
        // highlight, so a place is only ever replaced by another place.
        List(selection: Binding(get: { model.selection }, set: { if let place = $0 { model.selection = place } })) {
            ForEach(model.mailboxGroups) { group in
                Section {
                    ForEach(group.mailboxes) { box in
                        mailboxRow(box, in: group)
                        if isOpen(box.id) { folderRows(box) }
                    }
                    // An open mailbox is several rows, which dragging cannot place;
                    // Omhoog and Omlaag in its menu still work.
                    .onMove(perform: canOrganize && !group.mailboxes.contains { isOpen($0.id) } ? { source, destination in
                        Task { await model.moveMailboxes(in: group.role, from: source, to: destination) }
                    } : nil)
                } header: {
                    SidebarSectionHeader(sectionTitle(group.role))
                }
            }
            // Every row keeps its tag: badged rows once ignored clicks without one
            // (see the diary, 2026-10-22).
            Section {
                NavigationLink(value: SidebarItem.outings) {
                    CountedLabel(title: "Evenementen", icon: "ticket", count: model.outingsBadge)
                }
                .tag(SidebarItem.outings)
                NavigationLink(value: SidebarItem.tasks) {
                    CountedLabel(title: "Taken", icon: "checklist", count: model.tasksAwaitingReview)
                }
                .tag(SidebarItem.tasks)
            } header: {
                SidebarSectionHeader("Overal")
            }
        }
        .listStyle(.sidebar)
        // A folder opened elsewhere (a link, an outing's mail) shows under its mailbox.
        .onChange(of: model.selection, initial: true) { _, place in
            if let place, let id = place.mailboxId, place != .inbox(mailboxId: id) { setOpen(id, true) }
        }
        .alert("Naam van de mailbox", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Naam", text: $newName)
            Button("Bewaar") { if let box = renaming { rename(box) } }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(renaming.map { "\($0.address). Laat leeg om de naam van de provider te tonen." } ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UpdateBanner(appName: "Hedwig") { (NSApp.delegate as? AppDelegate)?.restart() }
                ConnectionBadge(
                    host: model.connection?.serverURL.host() ?? "", detail: model.me?.key.name ?? "",
                    reachable: model.reachability.isReachable, busy: model.isLoading, appName: "Hedwig")
            }
        }
    }

    private func mailboxRow(_ box: MailboxSummary, in group: AppModel.MailboxGroup) -> some View {
        let open = isOpen(box.id)
        let unread = model.unreadCounts[box.id] ?? 0
        // Folders are rarely needed, so the toggle only shows on hover or while they show.
        let showsToggle = if case .toggle = MailboxRowSlot(unread: unread, hovered: hovered == box.id, open: open) { true } else { false }
        return NavigationLink(value: SidebarItem.inbox(mailboxId: box.id)) {
            HStack(spacing: 6) {
                Label(mailboxTitle(box), systemImage: "tray")
                Spacer(minLength: 0)
                // One trailing slot: the unread count, or the toggle in its place.
                // Both stay laid out, so the row keeps its width when they swap.
                ZStack(alignment: .trailing) {
                    SidebarCount(count: unread)
                        .opacity(showsToggle ? 0 : 1)
                        .accessibilityHidden(showsToggle || unread == 0)
                    Button { toggle(box) } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help(open ? "Verberg mappen" : "Toon Archief, Verstuurd, Concepten en Spam")
                    .opacity(showsToggle ? 1 : 0)
                    .allowsHitTesting(showsToggle)
                    .accessibilityHidden(!showsToggle)
                }
            }
        }
        .onHover { inside in
            if inside { hovered = box.id } else if hovered == box.id { hovered = nil }
        }
        .help(box.address)
        .contextMenu {
            let index = group.mailboxes.firstIndex(of: box) ?? 0
            Button(open ? "Verberg mappen" : "Toon mappen") { toggle(box) }
            Divider()
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

    @ViewBuilder
    private func folderRows(_ box: MailboxSummary) -> some View {
        folderRow(.folder(.archive, mailboxId: box.id), "archivebox", waiting: model.reviews(in: .archive, mailboxId: box.id).count)
        folderRow(.folder(.sent, mailboxId: box.id), "paperplane", waiting: 0)
        folderRow(.drafts(mailboxId: box.id), "doc", waiting: model.drafts(in: box.id).count)
        folderRow(.folder(.spam, mailboxId: box.id), "xmark.bin", waiting: model.reviews(in: .spam, mailboxId: box.id).count)
    }

    private func folderRow(_ place: SidebarItem, _ icon: String, waiting: Int) -> some View {
        NavigationLink(value: place) {
            CountedLabel(title: placeName(place), icon: icon, count: waiting).padding(.leading, 14)
        }
        .tag(place)
    }

    private func isOpen(_ id: String) -> Bool { openMailboxes.split(separator: ",").contains { $0 == id } }

    private func setOpen(_ id: String, _ open: Bool) {
        guard isOpen(id) != open else { return }
        var ids = openMailboxes.split(separator: ",").map(String.init).filter { $0 != id }
        if open { ids.append(id) }
        openMailboxes = ids.joined(separator: ",")
    }

    private func toggle(_ box: MailboxSummary) {
        let open = !isOpen(box.id)
        withAnimation { setOpen(box.id, open) }
        // A hidden folder cannot stay selected; its mailbox's inbox takes over.
        if !open, let place = model.selection, place.mailboxId == box.id, place != .inbox(mailboxId: box.id) {
            model.selection = .inbox(mailboxId: box.id)
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

/// The private mailboxes are simply the inbox in the sidebar; Settings keeps "Privé".
private func sectionTitle(_ role: MailboxRole) -> String {
    role == .private ? "Inbox" : roleTitle(role)
}

func folderTitle(_ folder: MailFolder) -> String {
    switch folder {
    case .inbox: "Inbox"
    case .archive: "Archief"
    case .sent: "Verstuurd"
    case .spam: "Spam"
    case .trash: "Prullenbak"
    }
}

/// A mailbox's subfolder by name, as the sidebar and the window title show it.
func placeName(_ place: SidebarItem) -> String {
    switch place {
    case .folder(let folder, _): folderTitle(folder)
    case .drafts: "Concepten"
    case .inbox: "Inbox"
    case .tasks: "Taken"
    case .outings: "Evenementen"
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
