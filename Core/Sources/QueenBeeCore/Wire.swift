import Foundation

/// One message from the helper binary to the app.
public struct WireRequest: Codable, Equatable, Sendable {
    /// hook, route, sent, may-send, mcp, browser-mcp, or run for `qb run`, which carries no session.
    public var kind: String
    /// Which session the helper is running for, from `QB_SESSION`. The app puts a secret in it when it
    /// starts the session, so the value can't be made up by another session.
    public var session: String
    public var payload: JSONValue

    public init(kind: String, session: String, payload: JSONValue) {
        self.kind = kind; self.session = session; self.payload = payload
    }
}

/// Why a request to the app failed.
public struct WireError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }

    static func system(_ doing: String, _ code: Int32) -> WireError {
        WireError("\(doing): \(String(cString: strerror(code)))")
    }
}

/// How the helper and the app talk over the app's unix socket: each message is a four-byte big-endian length
/// followed by that many bytes of JSON.
public enum Wire {
    /// Far above any real message, and low enough that a garbled length fails fast instead of waiting for gigabytes.
    static let largestFrame = 64 * 1024 * 1024

    public static func frame(_ body: Data) -> Data {
        var framed = Data(capacity: body.count + 4)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(body)
        return framed
    }

    /// Pops one whole frame off the front of `buffer` and returns its body, or nil if it hasn't all arrived.
    public static func unframe(_ buffer: inout Data) -> Data? {
        guard let length = announcedLength(buffer), buffer.count >= 4 + length else { return nil }
        // A Data that has been sliced keeps its old indices, so everything here is relative to startIndex.
        let bodyStart = buffer.startIndex + 4
        let body = Data(buffer[bodyStart..<bodyStart + length])
        buffer = Data(buffer[(bodyStart + length)...])
        return body
    }

    private static func announcedLength(_ buffer: Data) -> Int? {
        guard buffer.count >= 4 else { return nil }
        return buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    /// Sends one request to the app and waits for its reply. Blocking, for the short-lived helper process.
    public static func send(_ request: WireRequest, socketPath: String, timeout: TimeInterval = 300) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.system("Could not open a socket", errno) }
        defer { close(fd) }

        // Without this, writing to an app that just quit would kill the helper with SIGPIPE instead of failing.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let seconds = max(timeout, 0)
        var limit = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw WireError("The socket path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw WireError.system("Could not reach Queen Bee", errno) }

        let framed = frame(try JSONEncoder().encode(request))
        try framed.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw code == EAGAIN ? WireError("Sending to Queen Bee timed out") : WireError.system("Could not send to Queen Bee", code)
                }
                sent += count
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let body = unframe(&buffer) { return try JSONValue.parse(body) }
            if let length = announcedLength(buffer), length > largestFrame {
                throw WireError("Queen Bee sent a reply that is too large to be real")
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw code == EAGAIN ? WireError("Waiting for Queen Bee timed out") : WireError.system("Could not read from Queen Bee", code)
            }
            if count == 0 { throw WireError("Queen Bee closed the connection before replying") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
