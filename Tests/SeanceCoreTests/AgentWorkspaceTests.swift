import Foundation
import SeanceCore
import Testing

@MainActor
@Test func workspaceRoundTripsOrderSelectionAndIsolatesConcurrentInstances() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = TabStore()
    let tab = store.open(directory: folder)
    try store.rename(tab, to: "Pinned name")
    let first = SavedAgent(key: SessionKey(providerID: "codex", sessionID: UUID().uuidString), tab: try store.tab(tab))
    let second = SavedAgent(key: SessionKey(providerID: "claude", sessionID: UUID().uuidString), tab: try store.tab(tab))
    let workspace = AgentWorkspace(agents: [second, first, second], selected: first.key)
    #expect(workspace.agents == [second, first])
    var original: AgentWorkspaceFile? = try AgentWorkspaceFile(directory: folder)
    try original?.save(workspace)
    let concurrent = try AgentWorkspaceFile(directory: folder)
    #expect(try concurrent.load().agents.isEmpty)
    original = nil
    let relaunched = try AgentWorkspaceFile(directory: folder)
    #expect(try relaunched.load() == workspace)
    try relaunched.save(AgentWorkspace(agents: [], selected: nil))
    #expect(try relaunched.load().selected == nil)
    withExtendedLifetime(concurrent) {}
}

@MainActor
@Test func onlyAttachedIdentitiesQualifyForSaving() {
    let attachments = SessionAttachments(), tab = TabID()
    let key = SessionKey(providerID: "claude", sessionID: UUID().uuidString)
    attachments.updateForeground([tab: "codex"])
    attachments.connect(UUID(), provider: "codex", in: tab)
    #expect(attachments.attachedKeys(in: tab).isEmpty)
    attachments.attach(key, to: tab)
    #expect(attachments.attachedKeys(in: tab) == [key])
    attachments.detach(key, from: tab)
    #expect(attachments.attachedKeys(in: tab).isEmpty)
    attachments.deferResume(key, in: tab)
    #expect(attachments.hasRow(for: key))
    #expect(!attachments.isAttached(key))
    attachments.close(tab)
    #expect(!attachments.hasRow(for: key))
}

@Test func claudeChecksLiveExternalSessionBeforeResume() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let registry = folder.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let key = SessionKey(providerID: "claude", sessionID: UUID().uuidString)
    let session = AgentSession(id: key, title: "Example", directory: folder, modifiedAt: .now)
    let file = registry.appendingPathComponent("\(getpid()).json")
    func register(started: Double) throws {
        try JSONSerialization.data(withJSONObject: ["pid": getpid(), "sessionId": key.sessionID, "startedAt": started])
            .write(to: file)
    }
    let provider = ClaudeSessionProvider(configDirectory: folder)
    try register(started: Date().timeIntervalSince1970 * 1000)
    #expect(throws: NSError.self) { try provider.launch(for: session) }
    try register(started: 1000)
    #expect(try provider.launch(for: session).arguments == ["--resume", key.sessionID])
    try FileManager.default.removeItem(at: file)
    #expect(try provider.launch(for: session).directory == folder)
}
