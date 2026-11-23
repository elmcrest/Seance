import Darwin
import Foundation
import SeanceCore
import SeanceIPC

@MainActor
public final class TabMCPServer {
    public var onClaudeHook: ((ClaudeHookKind, TabID, UUID) -> Void)?
    public let socketPath: String
    private let store: TabStore
    private let attachments: SessionAttachments?
    private let privateDirectory: URL?
    private var listener: DispatchSourceRead?
    private var pendingResumes: [TabID: (SessionLaunch, @MainActor () -> Void)] = [:]
    private var resumeProcesses: [TabID: DispatchSourceProcess] = [:]
    private var clients: Set<Int32> = []
    private struct HookedSession: Hashable {
        let tab: TabID
        let session: UUID
    }
    private var hookProcesses: [HookedSession: DispatchSourceProcess] = [:]

    public init(store: TabStore, attachments: SessionAttachments? = nil, socketPath: String? = ProcessInfo.processInfo.environment["SEANCE_LISTEN_SOCKET_PATH"]) throws {
        self.store = store
        self.attachments = attachments
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

    public func prepareResume(_ launch: SessionLaunch, in tab: TabID, onExit: @escaping @MainActor () -> Void) {
        pendingResumes[tab] = (launch, onExit)
    }

    public func forgetResume(in tab: TabID) {
        pendingResumes.removeValue(forKey: tab)
        resumeProcesses.removeValue(forKey: tab)?.cancel()
    }

    private func beginResume(in tab: TabID, pid: pid_t) -> Data {
        guard let (launch, onExit) = pendingResumes.removeValue(forKey: tab) else { return Data() }
        // The bridge execs the agent in place. Observe its PID independently of
        // agent hooks so launch errors and signal exits also free the session.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.forgetResume(in: tab)
            onExit()
        }
        resumeProcesses[tab] = source
        source.resume()
        return (try? JSONEncoder().encode([launch.executable] + launch.arguments)) ?? Data()
    }

    // SessionEnd never arrives when the agent crashes or is killed. Observe the
    // process that ran the hook so its exit also frees the session.
    private func observeClaudeHook(_ kind: ClaudeHookKind, tab: TabID, session: UUID, helper: pid_t) {
        let key = HookedSession(tab: tab, session: session)
        hookProcesses.removeValue(forKey: key)?.cancel()
        guard kind == .start, let agent = Self.agentProcess(above: helper) else { return }
        let source = DispatchSource.makeProcessSource(identifier: agent, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.hookProcesses.removeValue(forKey: key) else { return }
            source.cancel()
            self.onClaudeHook?(.end, tab, session)
        }
        hookProcesses[key] = source
        source.resume()
    }

    // The agent may run its hook through intermediate shells that exit with the
    // hook, so the nearest ancestor that is not a shell is taken to be the agent.
    private nonisolated static func agentProcess(above helper: pid_t) -> pid_t? {
        let shells: Set = ["sh", "bash", "dash", "zsh", "ksh", "fish"]
        var pid = helper
        for _ in 0..<8 {
            var info = proc_bsdinfo()
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            else { return nil }
            pid = pid_t(info.pbi_ppid)
            var name = [UInt8](repeating: 0, count: 64)
            guard pid > 1, pid != getpid(), proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
            if !shells.contains(String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)) { return pid }
        }
        return nil
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
                throw IPCError.message("SEANCE_LISTEN_SOCKET_PATH must be inside a private directory owned by this user")
            }
            // Serialize startup in this directory, including the bind-to-listen interval.
            // The directory inode survives stale socket removal and needs no lock file.
            let directoryFD = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(directoryFD) }
            guard flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            // An unclean exit leaves the socket file behind. Remove it only when
            // nothing accepts connections there, so a running instance stays intact.
            if lstat(socketPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
                do { Darwin.close(try LocalSocket.open(path: socketPath, listening: false)) }
                catch let error as POSIXError where error.code == .ECONNREFUSED { unlink(socketPath) }
                catch {}
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
        pendingResumes.removeAll()
        for process in resumeProcesses.values { process.cancel() }
        resumeProcesses.removeAll()
        for process in hookProcesses.values { process.cancel() }
        hookProcesses.removeAll()
        unlink(socketPath)
        listener.cancel()
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
            if header == Data(LocalSocket.resumeHeader.utf8) {
                guard let line = try input.next(), let id = UUID(uuidString: String(decoding: line, as: UTF8.self)) else { return }
                var pid: pid_t = 0
                var size = socklen_t(MemoryLayout.size(ofValue: pid))
                guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return }
                let reply = DispatchQueue.main.sync { beginResume(in: TabID(id), pid: pid) }
                try writeLine(reply, to: fd)
                return
            }
            if header == Data(ClaudeHook.header.utf8) {
                guard let payload = try input.next() else { return }
                let event = try JSONDecoder().decode(ClaudeHook.self, from: payload)
                var helper: pid_t = 0
                var size = socklen_t(MemoryLayout.size(ofValue: helper))
                if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &helper, &size) != 0 { helper = 0 }
                let peer = helper
                DispatchQueue.main.sync {
                    let tab = TabID(event.tabID)
                    if (try? store.tab(tab)) != nil {
                        onClaudeHook?(event.kind, tab, event.sessionID)
                        observeClaudeHook(event.kind, tab: tab, session: event.sessionID, helper: peer)
                    }
                }
                try writeLine(Data("ok".utf8), to: fd)
                return
            }
            let caller = UUID(uuidString: String(decoding: header, as: UTF8.self)).map(TabID.init)
            let session = DispatchQueue.main.sync { TabMCPSession(store: store, caller: caller, attachments: attachments) }
            defer { DispatchQueue.main.sync { session.disconnect() } }
            while let message = try input.next() {
                let reply = DispatchQueue.main.sync { session.handle(message) }
                try writeLine(reply ?? Data(), to: fd)
            }
        } catch {
            // A disconnected bridge ends only its own session.
        }
    }
}
