import Foundation

/// The outings' pictures, one version per outing, so the list, the page and
/// the mail card load each picture once.
@MainActor
final class OutingPictureCache {
    private var pictures: [String: (version: Date, picture: OutingPicture?)] = [:]
    private var loads: [String: (version: Date, task: Task<OutingPicture?, Never>)] = [:]
    private var order: [String] = []
    let limit: Int

    init(limit: Int = 80) { self.limit = limit }

    func cached(_ outingId: String, version: Date) -> OutingPicture?? {
        guard let hit = pictures[outingId], hit.version == version else { return nil }
        return .some(hit.picture)
    }

    func picture(_ outingId: String, version: Date, load: @escaping @MainActor () async -> OutingPicture?) async -> OutingPicture? {
        if let hit = cached(outingId, version: version) { return hit }
        if let running = loads[outingId], running.version == version { return await running.task.value }
        let task = Task { await load() }
        loads[outingId] = (version, task)
        let picture = await task.value
        if loads[outingId]?.version == version { loads[outingId] = nil }
        store(picture, for: outingId, version: version)
        return picture
    }

    private func store(_ picture: OutingPicture?, for outingId: String, version: Date) {
        if let known = pictures[outingId], known.version > version { return }
        pictures[outingId] = (version, picture)
        order.removeAll { $0 == outingId }
        order.append(outingId)
        while order.count > limit { pictures[order.removeFirst()] = nil }
    }
}

extension AppModel {
    /// The outing's picture, from the cache when this version was loaded before.
    public func picture(for outing: Outing) async -> OutingPicture? {
        guard let api, let image = outing.image else { return nil }
        return await pictureCache.picture(outing.id, version: image.updatedAt) {
            guard let data = try? await api.outingImage(outingId: outing.id, version: image.updatedAt) else { return nil }
            return OutingPicture(data: data)
        }
    }

    /// Without waiting: what the cache already holds, so a row does not flash.
    public func cachedPicture(for outing: Outing) -> OutingPicture? {
        guard let image = outing.image else { return nil }
        return pictureCache.cached(outing.id, version: image.updatedAt) ?? nil
    }

    public func pictureOptions(for outingId: String) async -> [OutingImageOption] {
        guard let api else { return [] }
        do {
            return try await api.outingImageOptions(outingId: outingId)
        } catch {
            report(error)
            return []
        }
    }

    public func pictureOption(_ option: OutingImageOption, of outingId: String) async -> OutingPicture? {
        guard let api, let data = try? await api.outingImageOption(outingId: outingId, optionId: option.id) else { return nil }
        return OutingPicture(data: data)
    }

    @discardableResult
    public func choosePicture(_ option: OutingImageOption, for outingId: String) async -> Bool {
        await changePicture(outingId) { try await $0.setOutingImage(outingId: outingId, .option(option.id)) }
    }

    /// Geen afbeelding: the colours from the title, and it stays that way.
    @discardableResult
    public func removePicture(from outingId: String) async -> Bool {
        await changePicture(outingId) { try await $0.deleteOutingImage(outingId: outingId) }
    }

    /// A pasted or dropped picture: bytes and files are uploaded, a link goes
    /// to the server, which fetches the picture or the page's share picture.
    @discardableResult
    public func setPicture(_ contents: PastedContents, for outingId: String) async -> Bool {
        guard let pasted = PastedPicture(contents) else {
            error = contents.isEmpty
                ? "Kopieer eerst een afbeelding of een link naar een website."
                : "Dat is geen afbeelding. Kopieer een afbeelding of een link naar een website."
            return false
        }
        return await changePicture(outingId) { api in
            switch pasted {
            case .link(let url):
                return try await api.setOutingImage(outingId: outingId, .link(url))
            case .image(let data):
                return try await api.setOutingImage(outingId: outingId, .upload(try await Self.uploadPicture(data, api)))
            case .file(let file):
                let data = try Data(contentsOf: file)
                return try await api.setOutingImage(outingId: outingId, .upload(try await Self.uploadPicture(data, api)))
            }
        }
    }

    private static func uploadPicture(_ data: Data, _ api: APIClient) async throws -> String {
        guard let prepared = PictureUpload.prepare(data) else { throw PictureError.notAPicture }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hedwig-pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).\(prepared.fileExtension)")
        try prepared.data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await api.upload(file: file)
    }

    @discardableResult
    private func changePicture(_ outingId: String, _ call: (APIClient) async throws -> Outing) async -> Bool {
        guard let api else { return false }
        pictureBusy.insert(outingId)
        defer { pictureBusy.remove(outingId) }
        do {
            apply(try await call(api))
            return true
        } catch PictureError.notAPicture, APIError.server(status: 400, _) {
            error = "Hedwig kan daar geen afbeelding van maken. Probeer een andere afbeelding of link."
        } catch {
            report(error)
        }
        return false
    }
}

enum PictureError: Error { case notAPicture }
