import Foundation

public struct UploadState: Codable, Sendable {
    public var id: String
    public var size: Int
    public var received: Int
}

extension APIClient {
    public func startUpload(size: Int) async throws -> UploadState {
        try await call("POST", "api/uploads", body: ["size": size])
    }

    public func uploadState(_ id: String) async throws -> UploadState {
        try await call("GET", "api/uploads/\(id)")
    }

    /// Sends a file in chunks (Cloudflare caps a request at 100 MB). Pass the
    /// id of an earlier, interrupted upload to continue where it stopped; each
    /// chunk is retried a few times before giving up. Returns the upload id
    /// for the module that wants the file.
    public func upload(
        file: URL, resuming id: String? = nil, chunkSize: Int = 16 * 1024 * 1024,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var state = try await {
            if let id, let known = try? await uploadState(id), known.size == size { return known }
            return try await startUpload(size: size)
        }()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var failures = 0
        while state.received < size {
            try handle.seek(toOffset: UInt64(state.received))
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            var request = request("PUT", "api/uploads/\(state.id)", query: [URLQueryItem(name: "offset", value: String(state.received))])
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 600
            do {
                let (data, response) = try await session.upload(for: request, from: chunk)
                try Self.check(response, data)
                state.received = try Self.decoder.decode(UploadState.self, from: data).received
                failures = 0
                progress(Double(state.received) / Double(max(size, 1)))
            } catch {
                failures += 1
                if failures > 4 { throw error }
                // The server knows how much arrived; continue from there.
                try await Task.sleep(for: .seconds(Double(failures * failures)))
                if let known = try? await uploadState(state.id) { state = known }
            }
        }
        return state.id
    }
}
