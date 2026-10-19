import Foundation

public enum ControlSocket {
    /// One socket per app, inside the user's Library, so only processes of this
    /// user reach them. BURROW_CONTROL_DIR points apps and CLI elsewhere, e.g.
    /// for a test copy.
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["BURROW_CONTROL_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Burrow/control", isDirectory: true)
    }

    public static func path(for app: String) -> String {
        directory.appendingPathComponent("\(app).sock").path
    }

    /// The apps whose socket exists, running or left behind by a crash.
    public static func apps() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ControlError("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
        }
        return addr
    }

    static func readLine(_ fd: Int32) -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            data.append(byte)
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

/// Accepts one JSON request per connection and answers it with one line.
public final class ControlSocketServer: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    public init(path: String, handler: @escaping @Sendable (Data) async -> Data) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("socket() failed") }
        var addr = try ControlSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ControlError("cannot listen on \(path)")
        }

        let listener = fd
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread {
                    let request = ControlSocket.readLine(client)
                    let done = DispatchSemaphore(value: 0)
                    let response = ResponseBox()
                    Task {
                        response.data = await handler(request)
                        done.signal()
                    }
                    done.wait()
                    ControlSocket.writeAll(client, response.data + Data("\n".utf8))
                    close(client)
                }
            }
        }
    }

    public func stop() {
        close(fd)
        unlink(path)
    }
}

private final class ResponseBox: @unchecked Sendable {
    var data = Data()
}

/// Sends one request and returns the answer, without the trailing newline.
public struct ControlSocketClient: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public init(app: String) { self.path = ControlSocket.path(for: app) }

    public func send(_ request: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("socket() failed") }
        defer { close(fd) }
        var addr = try ControlSocket.address(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ControlError("the app is not running, or its control socket is missing at \(path)") }
        // Sending and deleting wait for the person; give up after five minutes.
        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        ControlSocket.writeAll(fd, request + Data("\n".utf8))
        let reply = ControlSocket.readLine(fd)
        guard !reply.isEmpty else { throw ControlError("no answer from the app; is it waiting for the person to approve?") }
        return reply
    }
}
