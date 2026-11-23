import Foundation
import SeanceCore
import Testing

private struct SessionFixture {
    let root: URL
    let project: URL
    let directory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = root.appendingPathComponent("projects/test-project", isDirectory: true)
        directory = root.appendingPathComponent("working dir's ünicode", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ id: UUID, rows: [[String: Any]], in folder: URL? = nil) throws {
        let dest = (folder ?? project).appendingPathComponent(id.uuidString.lowercased() + ".jsonl")
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(0x0a)
        }
        try data.write(to: dest)
    }
}

@Test func discoversSessionsAcrossTranscriptVersions() async throws {
    let fixture = try SessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recent = UUID()
    let old = UUID()
    let main: [String: Any] = ["type": "user", "cwd": fixture.directory.path,
        "message": ["content": [["type": "text", "text": "First line\nSecond line"]]]]
    try fixture.write(recent, rows: [
        main,
        ["type": "assistant", "message": ["content": String(repeating: "x", count: 400_000)]],
        ["type": "ai-title", "aiTitle": "Automation"],
        ["type": "custom-title", "customTitle": "My session"],
    ])
    try fixture.write(old, rows: [["type": "user", "message": ["content": "An older session"]]])
    let index: [String: Any] = ["entries": [
        ["sessionId": old.uuidString, "projectPath": fixture.directory.path, "summary": "Indexed session"],
        ["sessionId": UUID().uuidString, "projectPath": fixture.directory.path, "summary": "Gone"],
    ]]
    try JSONSerialization.data(withJSONObject: index).write(to: fixture.project.appendingPathComponent("sessions-index.json"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
        ofItemAtPath: fixture.project.appendingPathComponent(old.uuidString.lowercased() + ".jsonl").path)
    try fixture.write(UUID(), rows: [["type": "user", "isSidechain": true, "cwd": fixture.directory.path]])
    try fixture.write(UUID(), rows: [["type": "user", "cwd": fixture.root.appendingPathComponent("missing").path]])
    try Data("incomplete json".utf8).write(to: fixture.project.appendingPathComponent(UUID().uuidString + ".jsonl"))
    let nested = fixture.project.appendingPathComponent("subagents")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try fixture.write(UUID(), rows: [main], in: nested)

    let provider = ClaudeSessionProvider(configDirectory: fixture.root)
    let sessions = try await provider.listSessions()
    #expect(sessions.map(\.title) == ["My session", "Indexed session"])
    let session = try #require(sessions.first)
    #expect(session.id == SessionKey(providerID: "claude", sessionID: recent.uuidString))
    let launch = try provider.launch(for: session)
    #expect(launch.executable == "claude")
    #expect(launch.arguments == ["--resume", recent.uuidString.lowercased()])
    #expect(launch.directory.path == fixture.directory.path)
    try FileManager.default.removeItem(at: fixture.directory)
    #expect(throws: CocoaError.self) { try provider.launch(for: session) }
}

@Test func sessionTitleFallsBackToFirstUserText() async throws {
    let fixture = try SessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write(UUID(), rows: [
        ["type": "user", "cwd": fixture.directory.path, "isMeta": true, "message": ["content": "Boilerplate"]],
        ["type": "user", "message": ["content": [["type": "tool_result", "content": "Tool output"]]]],
        ["type": "user", "message": ["content": [["type": "text", "text": "First line\nMore text"]]]],
    ])
    let provider = ClaudeSessionProvider(configDirectory: fixture.root)
    #expect(try await provider.listSessions().map(\.title) == ["First line"])
    let empty = ClaudeSessionProvider(configDirectory: fixture.root.appendingPathComponent("no-config"))
    #expect(try await empty.listSessions().isEmpty)
}

@MainActor
@Test func reservationsAndHookAttachmentsAreScopedToTheirTabAndProvider() {
    let attachments = SessionAttachments()
    let s = UUID().uuidString
    let key = SessionKey(providerID: "claude", sessionID: s)
    let hookKey = SessionKey(providerID: "claude", sessionID: s.lowercased())
    let otherProvider = SessionKey(providerID: "other", sessionID: s)
    let a = TabID(), b = TabID()

    #expect(attachments.reserve(key, for: a))
    #expect(!attachments.reserve(hookKey, for: b))
    #expect(attachments.reserve(otherProvider, for: b))
    attachments.attach(hookKey, to: a)
    attachments.attach(hookKey, to: b)
    attachments.detach(key, from: a)
    #expect(attachments.isAttached(key))
    attachments.close(b)
    #expect(!attachments.isAttached(key))
    #expect(!attachments.isAttached(otherProvider))
    #expect(attachments.reserve(key, for: a))
}
