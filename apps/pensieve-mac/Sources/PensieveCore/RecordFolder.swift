import Foundation

/// JSON as Pensieve keeps it on disk: ISO 8601 dates, sorted keys.
enum JSONFile {
    static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(type, from: $0) }
    }
}

/// A folder of `<id>.json` records beside the files they describe: the
/// outbox's uploads, the shelf's videos.
struct RecordFolder<Record: Codable & Identifiable>: Sendable where Record.ID == String {
    let dir: URL

    func newFile(extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONFile.write(record, to: file(record.id))
    }

    func all() -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { JSONFile.read(Record.self, from: $0) }
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// A stored path: inside the folder, or absolute for a file left where it was.
    func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
    }

    private func file(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
}
