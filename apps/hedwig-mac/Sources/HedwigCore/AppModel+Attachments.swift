import Foundation

extension AppModel {
    /// The files a person would call attachments; inline images belong to the mail's layout.
    public func attachments(messageId: String) async -> [Attachment] {
        // A facts-only key may not see them; the header then simply shows none.
        let list = try? await api?.attachments(messageId: messageId)
        return (list ?? []).filter { !$0.inline }
    }

    /// The attachment as a file for Quick Look, sharing and dragging; fetched once
    /// per message into the temporary folder, under its own name.
    public func attachmentFile(_ attachment: Attachment, messageId: String) async -> URL? {
        guard let api else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Hedwig/Attachments/\(messageId)/\(attachment.id)", directoryHint: .isDirectory)
        let url = folder.appending(path: Self.fileName(attachment.name))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            let data = try await api.attachment(messageId: messageId, id: attachment.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            report(error)
            return nil
        }
    }

    // A sender picks the name, so it never climbs out of its folder.
    static func fileName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "bijlage" : trimmed
    }
}
