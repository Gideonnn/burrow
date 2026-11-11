import BurrowUI
import HedwigCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The header scrolls with the message, as in Mail: one ScrollView holds the
/// header and a web view as tall as the mail, so the web view never scrolls
/// itself (see the diary, 2026-10-23-reader-header-scrolls-with-the-mail).
struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(remoteImagesKey) private var loadRemoteImages = false
    // The one message whose images the person chose to load.
    @State private var allowedMessageId: String?
    @State private var bodyHeight: CGFloat = 200

    private static let top = "top"

    var body: some View {
        if let message = model.detail {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            MessageHeader(message: message)
                            ShareBar(message: message)
                            ReviewBar(message: message)
                            if let summary = model.insights?.summary {
                                Label(summary, systemImage: "sparkles")
                                    .font(.callout)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if let html = message.bodyHtml {
                                RemoteImagesBar(
                                    html: html, messageId: message.id, allowed: $allowedMessageId,
                                    always: loadRemoteImages && model.loadsRemoteImagesUnasked(message),
                                    offersAlways: model.loadsRemoteImagesUnasked(message))
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 16)
                        .id(Self.top)
                        Divider().padding(.horizontal, 28)
                        MessageBody(
                            message: message,
                            allowRemote: allowedMessageId == message.id
                                || (loadRemoteImages && model.loadsRemoteImagesUnasked(message)),
                            height: $bodyHeight)
                    }
                }
                .onChange(of: message.id) { proxy.scrollTo(Self.top, anchor: .top) }
            }
            .safeAreaInset(edge: .bottom) { SuggestionBar() }
        } else {
            ContentUnavailableView("Geen bericht geselecteerd", systemImage: "envelope")
        }
    }
}

/// The mail itself, as tall as it is, inside the reader's scroll view.
struct MessageBody: View {
    let message: MessageDetail
    let allowRemote: Bool
    @Binding var height: CGFloat

    var body: some View {
        if let html = message.bodyHtml {
            HTMLView(html: html, allowRemote: allowRemote, height: $height)
                .frame(height: height)
        } else {
            // Mail's default message font, which no text style matches.
            Text(message.bodyText ?? message.snippet)
                .font(.custom("Helvetica", size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
        }
    }
}

/// After Mail: the sender is the strongest line, the subject sits under it,
/// then compact Aan/Kopie/Antwoord aan lines. The date stays top right.
/// Mail sizes its header from the message font (12 pt): the sender at 14.
struct MessageHeader: View {
    let message: MessageDetail

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.from.display, size: 32)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(message.from.display)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .help(message.from.email)
                        .contextMenu {
                            SenderMenu(address: message.from, mailboxId: message.mailboxId)
                        }
                    Spacer(minLength: 0)
                    Text(MailFormat().headerDate(message.receivedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.bottom, 2)
                Text(message.subject)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                RecipientLinesView(lines: message.recipientLines)
                    .id(message.id)
                    .padding(.top, 2)
                MessageTags(message: message)
                if message.hasAttachments {
                    AttachmentStrip(messageId: message.id).padding(.top, 6)
                }
            }
        }
    }
}

/// The mail's files: a click shows one in Quick Look (arrows step through the
/// rest), dragging or sharing hands over the file, fetched when first needed.
struct AttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let messageId: String
    @State private var files: [Attachment] = []
    @State private var fetched: [String: URL] = [:]
    @State private var preview: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    let item = AttachmentItem(name: file.name) { [model, messageId] in
                        guard let url = await model.attachmentFile(file, messageId: messageId) else { throw CocoaError(.fileReadUnknown) }
                        return url
                    }
                    Button { Task { await show(file) } } label: {
                        Label {
                            Text("\(file.name) \(Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).foregroundStyle(.secondary))")
                                .lineLimit(1)
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: file.contentType) ?? .data))
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Voorvertoning")
                    .draggable(item)
                    .contextMenu {
                        Button("Voorvertoning") { Task { await show(file) } }
                        Button("Open") { Task { if let url = await model.attachmentFile(file, messageId: messageId) { NSWorkspace.shared.open(url) } } }
                        Button("Bewaar in Downloads") { Task { await saveToDownloads(file) } }
                        ShareLink(item: item, preview: SharePreview(file.name))
                    }
                }
            }
        }
        .scrollClipDisabled()
        .quickLookPreview($preview, in: files.compactMap { fetched[$0.id] })
        .task(id: messageId) {
            files = []
            fetched = [:]
            files = await model.attachments(messageId: messageId)
        }
    }

    private func show(_ file: Attachment) async {
        guard let url = await model.attachmentFile(file, messageId: messageId) else { return }
        fetched[file.id] = url
        preview = url
    }

    private func saveToDownloads(_ file: Attachment) async {
        guard let url = await model.attachmentFile(file, messageId: messageId),
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        var target = downloads.appending(path: url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let base = "\(url.deletingPathExtension().lastPathComponent) \(n)"
            target = downloads.appending(path: url.pathExtension.isEmpty ? base : "\(base).\(url.pathExtension)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            model.error = error.localizedDescription
        }
    }
}

/// An attachment for drag and share; the file is fetched only when it is dropped or shared.
struct AttachmentItem: Transferable {
    let name: String
    let file: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in SentTransferredFile(try await item.file()) }
            .suggestedFileName { $0.name }
    }
}

/// Names only; each line shows its addresses on hover. Long lists end in
/// "+3", which opens every line in full.
struct RecipientLinesView: View {
    let lines: [RecipientLine]
    @State private var expanded = false

    private static let limit = 3

    var body: some View {
        let compact = lines.filter { $0.kind != .replyTo }
        VStack(alignment: .leading, spacing: 2) {
            if expanded {
                ForEach(lines) { line in
                    RecipientText(line: line, limit: nil) {}
                }
                Button("Minder") { expanded = false }
                    .buttonStyle(.link)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        ForEach(compact) { line in
                            RecipientText(line: line, limit: Self.limit) { expanded = true }.fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(compact) { line in
                            RecipientText(line: line, limit: Self.limit) { expanded = true }
                        }
                    }
                }
                ForEach(lines.filter { $0.kind == .replyTo }) { line in
                    RecipientText(line: line, limit: Self.limit) { expanded = true }
                }
            }
        }
        .font(.callout)
    }
}

private struct RecipientText: View {
    let line: RecipientLine
    let limit: Int?
    let expand: () -> Void

    var body: some View {
        let names = line.names(limit: limit)
        // Mail: the label in the primary colour, the names in grey after a wide gap.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(line.label):").fixedSize()
            Text(names.shown)
                .foregroundStyle(.secondary)
                .lineLimit(limit == nil ? nil : 1)
                .truncationMode(.tail)
            if names.more > 0 {
                Button("+\(names.more)", action: expand)
                    .buttonStyle(.link)
                    .help("Toon iedereen")
            }
        }
        .help(line.tooltip)
        .contextMenu {
            Button("Kopieer adressen") { copy(line.addresses.map(\.email).joined(separator: ", ")) }
        }
    }
}

/// The same tags as the message row: category, Antwoord nodig, labels, and
/// the lock for sensitive mail.
private struct MessageTags: View {
    let message: MessageDetail

    var body: some View {
        let category = message.facts?.categoryTitle
        let sensitive = message.facts?.sensitive == true
        if category != nil || message.flagged || !message.labels.isEmpty || sensitive {
            HStack(spacing: 5) {
                if let category { Tag(text: category, color: .teal) }
                if message.flagged { Tag(text: "Antwoord nodig", color: .orange) }
                ForEach(message.labels, id: \.self) { Tag(text: $0, color: .secondary) }
                if sensitive {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .help("Bevat gevoelige gegevens; gaat nooit naar een cloud-AI")
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct SenderMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let address: Address
    let mailboxId: String

    var body: some View {
        Button("Stuur bericht") { openWindow(value: ComposeDraft(mailboxId: mailboxId, to: Address.format([address]))) }
            .disabled(model.me?.can(.send) != true)
        Button("Kopieer adres") { copy(address.email) }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(initials.uppercased())
            // Sized to the circle, like BurrowUI's PersonBadge; no text style scales with it.
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(BurrowColor.person(name)))
    }
}

let remoteImagesKey = "loadRemoteImages"

/// Remote images tell the sender when and where mail was opened, so they load
/// only when the person asks: for this message, or always (Instellingen). Spam
/// and doubt cases offer only this message: nothing is remembered.
struct RemoteImagesBar: View {
    let html: String
    let messageId: String
    @Binding var allowed: String?
    let always: Bool
    var offersAlways = true
    @AppStorage(remoteImagesKey) private var loadAlways = false

    var body: some View {
        if !always, allowed != messageId, HTMLView.hasRemoteContent(html) {
            HStack(spacing: 8) {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text("Externe afbeeldingen zijn niet geladen.").foregroundStyle(.secondary)
                Spacer()
                Button("Afbeeldingen laden") { allowed = messageId }
                if offersAlways { Button("Altijd") { loadAlways = true } }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Reply suggestions from the bot: each chip opens a ready reply to edit and
/// send. Hidden when there is nothing to suggest.
struct SuggestionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let replies = model.insights?.replies ?? []
        if model.me?.can(.send) == true, model.insightsLoading || !replies.isEmpty || model.insights == nil {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                if model.insightsLoading {
                    Text("Antwoorden bedenken…").foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                } else if replies.isEmpty {
                    Button("Stel antwoorden voor") { Task { await model.loadInsights() } }
                        .buttonStyle(.borderless)
                } else {
                    ForEach(replies, id: \.self) { reply in
                        Button(reply.label) {
                            if let draft = model.compose(reply: reply) { openWindow(value: draft) }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .fixedSize()
                    }
                }
                Spacer()
            }
            .font(.callout)
            .modifier(SuggestionBackground())
        }
    }
}

/// A floating glass bar on macOS 26, the window's bar material before.
private struct SuggestionBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(Glass(shape: Capsule()))
                .padding(12)
        } else {
            content
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }
}
