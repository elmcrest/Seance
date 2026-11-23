import Darwin
import Foundation
import SeanceCore
import SeanceIPC

@MainActor
public final class TabMCPServer {
    public var onClaudeHook: ((ClaudeHookKind, TabID, UUID) -> Void)?
    public let socketPath: String
    private let store: TabStore
    private let privateDirectory: URL?
    private var listener: DispatchSourceRead?
    private var clients: Set<Int32> = []

    public init(store: TabStore, socketPath: String? = ProcessInfo.processInfo.environment["SEANCE_SOCKET_PATH"]) throws {
        self.store = store
        if let socketPath {
            self.socketPath = socketPath
            self.privateDirectory = nil
        } else {
            // The macOS per-user temporary path may already exceed sockaddr_un.sun_path.
            let directory = URL(fileURLWithPath: "/tmp/seance-" + UUID().uuidString)
            self.privateDirectory = directory
            self.socketPath = directory.appendingPathComponent("mcp.sock").path
        }
    }

    public func start() throws {
        guard listener == nil else { return }
        if let privateDirectory {
            try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        do {
            let parent = (socketPath as NSString).deletingLastPathComponent
            var info = stat()
            guard lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
                throw IPCError.message("SEANCE_SOCKET_PATH must be inside a private directory owned by this user")
            }
            let fd = try LocalSocket.open(path: socketPath, listening: true)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.acceptClients(on: fd) }
            source.setCancelHandler { Darwin.close(fd) }
            listener = source
            source.resume()
        } catch {
            if let privateDirectory { rmdir(privateDirectory.path) }
            throw error
        }
    }

    public func stop() {
        guard let listener else { return }
        self.listener = nil
        listener.cancel()
        unlink(socketPath)
        if let privateDirectory { rmdir(privateDirectory.path) }
        for fd in clients { shutdown(fd, SHUT_RDWR) }
    }

    private func acceptClients(on listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 && errno == EINTR { continue }
            guard fd >= 0 else { return }
            do {
                try LocalSocket.configure(fd)
                guard fcntl(fd, F_SETFL, 0) == 0 else { throw IPCError.message("Cannot configure socket") }
            } catch {
                Darwin.close(fd)
                continue
            }
            clients.insert(fd)
            DispatchQueue.global(qos: .utility).async { [self] in
                serve(fd)
                DispatchQueue.main.async {
                    self.clients.remove(fd)
                    Darwin.close(fd)
                }
            }
        }
    }

    // The socket carries an identity line followed by stdio frames. A blank reply acknowledges
    // a notification internally and is never forwarded to the MCP client's stdout.
    private nonisolated func serve(_ fd: Int32) {
        var input = LineReader(fd)
        do {
            guard let header = try input.next() else { return }
            if header == Data(ClaudeHook.header.utf8) {
                guard let payload = try input.next() else { return }
                let event = try JSONDecoder().decode(ClaudeHook.self, from: payload)
                DispatchQueue.main.sync {
                    let tab = TabID(event.tabID)
                    if (try? store.tab(tab)) != nil {
                        onClaudeHook?(event.kind, tab, event.sessionID)
                    }
                }
                try writeLine(Data("ok".utf8), to: fd)
                return
            }
            let caller = UUID(uuidString: String(decoding: header, as: UTF8.self)).map(TabID.init)
            let session = DispatchQueue.main.sync { TabMCPSession(store: store, caller: caller) }
            while let message = try input.next() {
                let reply = DispatchQueue.main.sync { session.handle(message) }
                try writeLine(reply ?? Data(), to: fd)
            }
        } catch {
            // A disconnected bridge ends only its own session.
        }
    }
}
