import Foundation
import Observation

public struct SessionKey: Hashable, Sendable {
    public let providerID: String
    public let sessionID: String

    public init(providerID: String, sessionID: String) {
        self.providerID = providerID
        self.sessionID = UUID(uuidString: sessionID)?.uuidString.lowercased() ?? sessionID
    }
}

public struct AgentSession: Identifiable, Sendable {
    public let id: SessionKey
    public let title: String
    public let directory: URL
    public let modifiedAt: Date

    public init(id: SessionKey, title: String, directory: URL, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.directory = directory
        self.modifiedAt = modifiedAt
    }
}

public struct SessionLaunch: Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: URL

    public init(executable: String, arguments: [String], directory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
    }
}

public protocol AgentSessionProvider: Sendable {
    func listSessions() async throws -> [AgentSession]
    func launch(for session: AgentSession) throws -> SessionLaunch
}

@MainActor @Observable
public final class SessionAttachments {
    private var tabsBySession: [SessionKey: Set<TabID>] = [:]

    public init() {}

    public func isAttached(_ key: SessionKey) -> Bool {
        tabsBySession[key] != nil
    }

    public func reserve(_ key: SessionKey, for tab: TabID) -> Bool {
        guard !isAttached(key) else { return false }
        attach(key, to: tab)
        return true
    }

    public func attach(_ key: SessionKey, to tab: TabID) {
        tabsBySession[key, default: []].insert(tab)
    }

    public func detach(_ key: SessionKey, from tab: TabID) {
        tabsBySession[key]?.remove(tab)
        if tabsBySession[key]?.isEmpty == true {
            tabsBySession.removeValue(forKey: key)
        }
    }

    public func close(_ tab: TabID) {
        for key in tabsBySession.keys {
            detach(key, from: tab)
        }
    }
}
