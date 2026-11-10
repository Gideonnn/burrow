import BurrowUI
import HedwigCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: MailboxSummary?
    @State private var newName = ""
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
                        DisclosureGroup(isExpanded: expanded(box)) {
                            folderRows(box)
                        } label: {
                            mailboxRow(box, in: group)
                        }
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
                NavigationLink(value: SidebarItem.tasks) {
                    CountedLabel(title: "Taken", icon: "checklist", count: model.tasksAwaitingReview)
                }
                .tag(SidebarItem.tasks)
                NavigationLink(value: SidebarItem.shared) {
                    CountedLabel(title: "Gedeeld", icon: "person.2", count: 0)
                }
                .tag(SidebarItem.shared)
                // The reader's share button names the housemates.
                .task(id: model.me?.person.id) { await model.loadPeople() }
            } header: {
                SidebarSectionHeader("Overal")
            }
        }
        .listStyle(.sidebar)
        // A folder opened elsewhere (a link, burrowctl) shows under its mailbox.
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
        return NavigationLink(value: SidebarItem.inbox(mailboxId: box.id)) {
            HStack(spacing: 6) {
                Label(mailboxTitle(box), systemImage: box.needsReconnect == true ? "exclamationmark.triangle" : "tray")
                Spacer(minLength: 0)
                SidebarCount(count: model.unreadCounts[box.id] ?? 0)
            }
        }
        .help(box.address)
        .modifier(MailDrop(place: .inbox(mailboxId: box.id)))
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
            CountedLabel(title: placeName(place), icon: icon, count: waiting)
        }
        .modifier(MailDrop(place: place))
        .tag(place)
    }

    private func expanded(_ box: MailboxSummary) -> Binding<Bool> {
        Binding(get: { isOpen(box.id) }, set: { if $0 != isOpen(box.id) { toggle(box) } })
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
    case .shared: "Gedeeld"
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

/// Mail dragged from the list onto Inbox, Archief or Spam of its own mailbox moves there.
private struct MailDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let place: SidebarItem

    func body(content: Content) -> some View {
        switch place {
        case .inbox, .folder(.archive, _), .folder(.spam, _):
            content.dropDestination(for: String.self) { ids, _ in
                guard model.canMove(ids, to: place) else { return false }
                Task { await model.move(ids, to: place) }
                return true
            }
        default:
            content
        }
    }
}
