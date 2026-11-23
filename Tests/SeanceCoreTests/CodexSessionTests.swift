import Foundation
import SQLite3
import Testing
import SeanceCore

@Test func codexDiscoversAndResumesLocalInteractiveRollouts() async throws {
    let files = FileManager.default
    let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: home) }
    let cwd = home.appendingPathComponent("project's ünicode", isDirectory: true)
    let sessions = home.appendingPathComponent("sessions/2026/11/23", isDirectory: true)
    for directory in [cwd, sessions] { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
    func rollout(_ source: Any, directory: URL, root: URL) throws -> UUID {
        let id = UUID()
        let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": id.uuidString, "cwd": directory.path, "source": source]]
        var data = try JSONSerialization.data(withJSONObject: metadata)
        data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "user_message", "message": "First request"]]))
        try data.write(to: root.appendingPathComponent("rollout-2026-11-23T12-00-00-" + id.uuidString + ".jsonl"))
        return id
    }

    let cli = try rollout("cli", directory: cwd, root: sessions)
    let ide = try rollout("vscode", directory: cwd, root: sessions)
    _ = try rollout("exec", directory: cwd, root: sessions)
    _ = try rollout(["subagent": "review"], directory: cwd, root: sessions)
    _ = try rollout("cli", directory: home.appendingPathComponent("deleted"), root: sessions)
    _ = try rollout("cli", directory: cwd, root: home)

    let provider = CodexSessionProvider(home: home)
    let initial = try await provider.listSessions()
    #expect(Set(initial.map(\.id.sessionID)) == Set([cli, ide].map { $0.uuidString.lowercased() }))
    #expect(initial.allSatisfy { $0.title == "First request" })

    var db: OpaquePointer?
    let dbPath = home.appendingPathComponent("state_5.sqlite").path
    try #require(sqlite3_open(dbPath, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = """
        CREATE TABLE threads(id TEXT, cwd TEXT, title TEXT, name TEXT, source TEXT, archived INTEGER);
        INSERT INTO threads VALUES ('\(cli)', '\(cwd.path.replacingOccurrences(of: "'", with: "''"))', 'Auto', 'Named session', 'cli', 0);
        INSERT INTO threads VALUES ('\(ide)', '/', 'Archived', NULL, 'vscode', 1);
        """
    try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    let listed = try await provider.listSessions()
    #expect(listed.count == 1)
    let session = try #require(listed.first)
    #expect(session.title == "Named session")
    let launch = try provider.launch(for: session)
    #expect(launch.executable == "codex")
    #expect(launch.arguments == ["resume", cli.uuidString.lowercased()])
    #expect(launch.directory.path == cwd.path)
    try files.removeItem(at: cwd)
    #expect(throws: CocoaError.self) { try provider.launch(for: session) }
}
