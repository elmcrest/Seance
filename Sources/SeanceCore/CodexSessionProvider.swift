import Foundation
import SQLite3

public actor CodexSessionProvider: AgentSessionProvider {
    private let home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            self.home = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            self.home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
    }

    private struct Metadata {
        let cwd: String
        let title: String?
        let visible: Bool
    }

    // The index supplies names without reading conversation history. Rollout files
    // determine which conversations still exist after cleanup or migration.
    private func indexedMetadata() -> [UUID: Metadata] {
        let path = home.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Older versions of the index only have title.
        for expression in ["COALESCE(NULLIF(name, ''), title)", "title"] {
            let query = "SELECT id, cwd, " + expression + ", source, archived FROM threads"
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK { break }
        }
        guard let statement else { return [:] }
        func column(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
        var result: [UUID: Metadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = column(0).flatMap(UUID.init(uuidString:)), let cwd = column(1) else { continue }
            result[id] = Metadata(cwd: cwd, title: column(2),
                                  visible: sqlite3_column_int(statement, 4) == 0 && Self.interactive(column(3)))
        }
        return result
    }

    private static func interactive(_ source: String?) -> Bool {
        source == nil || ["cli", "vscode", "appserver", "appServer", "app_server"].contains(source)
    }

    private func rolloutMetadata(_ file: URL, id: UUID) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        var cwd: String?
        var preview: String?
        for line in data.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = row["payload"] as? [String: Any] else { continue }
            if row["type"] as? String == "session_meta" {
                guard let rawID = (payload["id"] ?? payload["session_id"]) as? String, UUID(uuidString: rawID) == id,
                      !(payload["source"] is [String: Any]), Self.interactive(payload["source"] as? String)
                else { return nil }
                cwd = payload["cwd"] as? String
            }
            if row["type"] as? String == "event_msg", payload["type"] as? String == "user_message" {
                preview = payload["message"] as? String
                break
            }
        }
        guard let cwd else { return nil }
        return Metadata(cwd: cwd, title: preview, visible: true)
    }

    public func listSessions() async throws -> [AgentSession] {
        let files = FileManager.default
        let directory = home.appendingPathComponent("sessions")
        guard files.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let entries = files.enumerator(at: directory, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadNoPermission) }
        let index = indexedMetadata()
        var sessions: [SessionKey: AgentSession] = [:]
        while let file = entries.nextObject() as? URL {
            try Task.checkCancellation()
            let stem = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jsonl", stem.hasPrefix("rollout-"),
                  let id = UUID(uuidString: String(stem.suffix(36))),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  let info = index[id] ?? rolloutMetadata(file, id: id), info.visible,
                  info.cwd.hasPrefix("/"), Self.directoryExists(info.cwd) else { continue }
            let key = SessionKey(providerID: "codex", sessionID: id.uuidString)
            if let previous = sessions[key], previous.modifiedAt >= modified { continue }
            let line = info.title?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)
            let title = line.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) } ?? String(key.sessionID.prefix(8))
            sessions[key] = AgentSession(id: key, title: title, directory: URL(fileURLWithPath: info.cwd, isDirectory: true),
                                         modifiedAt: modified)
        }
        return Array(sessions.values)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    public nonisolated func launch(for session: AgentSession) throws -> SessionLaunch {
        guard session.id.providerID == "codex", UUID(uuidString: session.id.sessionID) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard Self.directoryExists(session.directory.path) else { throw CocoaError(.fileNoSuchFile) }
        return SessionLaunch(executable: "codex", arguments: ["resume", session.id.sessionID], directory: session.directory)
    }
}
