import Darwin
import Foundation

package enum IPCError: LocalizedError {
    case message(String)

    package var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

package enum LocalSocket {
    package static let resumeHeader = "seance-resume-v1"

    package static func open(path: String, listening: Bool) throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard path.hasPrefix("/"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              !path.utf8.contains(0) else {
            throw IPCError.message("Expected an absolute Unix socket path of at most 103 bytes")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        do {
            try configure(fd)
            let length = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    listening ? Darwin.bind(fd, $0, length)
                              : Darwin.connect(fd, $0, length)
                }
            }
            guard result == 0 else { throw posixError() }
            if listening {
                do {
                    guard chmod(path, 0o600) == 0, listen(fd, 16) == 0,
                          fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw posixError() }
                } catch {
                    unlink(path)
                    throw error
                }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    package static func configure(_ fd: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw posixError() }
    }
}

// Each reader belongs to a single worker. Bound retained data even if a peer never sends a newline.
package struct LineReader {
    private let fd: Int32
    private var pending = Data()
    private var buffer = [UInt8](repeating: 0, count: 8192)

    package init(_ fd: Int32) { self.fd = fd }

    package mutating func next() throws -> Data? {
        let limit = 1 << 20
        while true {
            if let split = pending.firstIndex(of: 10) {
                guard pending.distance(from: pending.startIndex, to: split) <= limit
                else { throw IPCError.message("Message exceeds 1 MiB") }
                let line = Data(pending[..<split])
                pending.removeSubrange(...split)
                return line
            }
            guard pending.count <= limit else { throw IPCError.message("Message exceeds 1 MiB") }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 {
                guard pending.isEmpty else { throw IPCError.message("Incomplete message at end of stream") }
                return nil
            }
            pending.append(contentsOf: buffer.prefix(count))
        }
    }
}

package func writeLine(_ data: Data, to fd: Int32) throws {
    var framed = data
    framed.append(10)
    try framed.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw posixError() }
            offset += count
        }
    }
}
