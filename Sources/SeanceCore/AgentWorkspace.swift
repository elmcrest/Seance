import Darwin
import Foundation

public struct SavedAgent: Codable, Equatable, Sendable {
    public let key: SessionKey
    public let directory: URL
    public let title: String
    public let titleOverride: String?

    public init(key: SessionKey, tab: Tab) {
        self.key = key
        directory = tab.directory
        title = tab.programTitle ?? tab.title
        titleOverride = tab.titleOverride
    }
}

public struct AgentWorkspace: Codable, Equatable, Sendable {
    public let agents: [SavedAgent]
    public let selected: SessionKey?

    public init(agents: [SavedAgent], selected: SessionKey?) {
        var seen = Set<SessionKey>()
        self.agents = agents.filter {
            ["claude", "codex"].contains($0.key.providerID) && UUID(uuidString: $0.key.sessionID) != nil &&
                $0.directory.isFileURL && seen.insert($0.key).inserted
        }
        self.selected = selected.flatMap { seen.contains($0) ? $0 : nil } ?? self.agents.first?.key
    }
}

/// Each concurrent app instance owns a slot until it quits. The lock stays on a
/// separate inode so replacing a snapshot atomically never drops the lock.
public final class AgentWorkspaceFile {
    private let lock: Int32
    private let file: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var slot = 0
        while true {
            let base = directory.appendingPathComponent("workspace-\(slot)")
            let fd = open(base.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lock = fd
                file = base.appendingPathExtension("json")
                return
            }
            let error = errno
            close(fd)
            guard error == EWOULDBLOCK else { throw POSIXError(.init(rawValue: error) ?? .EIO) }
            slot += 1
        }
    }

    deinit { close(lock) }

    public func load() throws -> AgentWorkspace {
        do {
            let saved = try JSONDecoder().decode(AgentWorkspace.self, from: Data(contentsOf: file))
            return AgentWorkspace(agents: saved.agents, selected: saved.selected)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return AgentWorkspace(agents: [], selected: nil)
        }
    }

    public func save(_ workspace: AgentWorkspace) throws {
        try JSONEncoder().encode(workspace).write(to: file, options: .atomic)
    }
}
