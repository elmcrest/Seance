import Foundation
import Observation

public struct SessionKey: Codable, Hashable, Sendable {
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

    var transcripts: [URL]

    public init(id: SessionKey, title: String, directory: URL, modifiedAt: Date, transcripts: [URL] = []) {
        self.transcripts = transcripts
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

    private var clientsByTab: [TabID: [UUID: String]] = [:]

    public init() {}

    private var foreground: [TabID: String] = [:]

    public func updateForeground(_ current: [TabID: String]) {
        if foreground != current { foreground = current }
    }

    public func providers(in tab: TabID) -> [String] {
        var providers = Set(tabsBySession.compactMap { key, tabs in
            tabs.contains(tab) ? key.providerID : nil
        })
        if let provider = foreground[tab] { providers.insert(provider) }
        if let clients = clientsByTab[tab] { providers.formUnion(clients.values) }
        return providers.sorted()
    }

    public func connect(_ client: UUID, provider: String, in tab: TabID) {
        clientsByTab[tab, default: [:]][client] = provider
    }

    public func disconnect(_ client: UUID, in tab: TabID) {
        clientsByTab[tab]?.removeValue(forKey: client)
        if clientsByTab[tab]?.isEmpty == true { clientsByTab.removeValue(forKey: tab) }
    }

    private var deferred: [TabID: SessionKey] = [:]

    public func deferResume(_ key: SessionKey?, in tab: TabID) { deferred[tab] = key }

    public func hasRow(for key: SessionKey) -> Bool { isAttached(key) || deferred.values.contains(key) }

    public func attachedKeys(in tab: TabID) -> [SessionKey] {
        tabsBySession.compactMap { $0.value.contains(tab) ? $0.key : nil }.sorted {
            ($0.providerID, $0.sessionID) < ($1.providerID, $1.sessionID)
        }
    }

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
        deferred.removeValue(forKey: tab)
        foreground.removeValue(forKey: tab)
        clientsByTab.removeValue(forKey: tab)
        for key in tabsBySession.keys {
            detach(key, from: tab)
        }
    }
}
