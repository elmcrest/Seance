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
    // An interrupted read is reported as incomplete: a conversation missing from it
    // may be archived, which its rollout file cannot tell.
    private func indexedMetadata() -> (rows: [UUID: Metadata], complete: Bool) {
        let path = home.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            var info = stat()
            let missing = lstat(path, &info) == -1 && errno == ENOENT
            return ([:], missing)
        }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Older versions of the index only have title.
        for expression in ["COALESCE(NULLIF(name, ''), title)", "title"] {
            let query = "SELECT id, cwd, " + expression + ", source, archived FROM threads"
            let status = sqlite3_prepare_v2(db, query, -1, &statement, nil)
            if status == SQLITE_OK { break }
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { return ([:], false) }
        }
        guard let statement else { return ([:], false) }
        func column(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
        var result: [UUID: Metadata] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let id = column(0).flatMap(UUID.init(uuidString:)), let cwd = column(1) {
                result[id] = Metadata(cwd: cwd, title: column(2),
                                      visible: sqlite3_column_int(statement, 4) == 0 && Self.interactive(column(3)))
            }
            status = sqlite3_step(statement)
        }
        return (result, status == SQLITE_DONE)
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

    private nonisolated static func rolloutID(_ file: URL) -> UUID? {
        let rollout = file.pathExtension == "zst" ? file.deletingPathExtension() : file
        guard rollout.pathExtension == "jsonl" else { return nil }
        let stem = rollout.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("rollout-") else { return nil }
        // A continuation appends "_<uuid>" after the original thread ID.
        let threadPart = stem.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard threadPart.count == 1 || UUID(uuidString: String(threadPart[1])) != nil else { return nil }
        return UUID(uuidString: String(threadPart[0].suffix(36)))
    }

    // Codex, or the app-server daemon its clients share, keeps the rollout of every
    // running conversation open. Resuming one of those would start a second writer.
    private nonisolated static func runningSessions() -> Set<UUID> {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        var running: Set<UUID> = []
        for pid in pids.prefix(max(0, Int(count))) {
            var name = [UInt8](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  String(decoding: name.prefix { $0 != 0 }, as: UTF8.self).hasPrefix("codex") else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
            guard needed > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: needed / stride + 16)
            let used = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride)))
            for descriptor in descriptors.prefix(max(0, used) / stride)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                     Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0,
                      info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let file = URL(fileURLWithPath: path)
                if let id = rolloutID(file) {
                    running.insert(id)
                }
            }
        }
        return running
    }

    public func listSessions() async throws -> [AgentSession] {
        let files = FileManager.default
        let directory = home.appendingPathComponent("sessions")
        guard files.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let entries = files.enumerator(at: directory, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadNoPermission) }
        let index = indexedMetadata()
        let running = Self.runningSessions()
        var sessions: [SessionKey: AgentSession] = [:]
        while let file = entries.nextObject() as? URL {
            try Task.checkCancellation()
            guard let id = Self.rolloutID(file), !running.contains(id),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  let info = index.rows[id] ?? (index.complete && file.pathExtension == "jsonl" ? rolloutMetadata(file, id: id) : nil), info.visible,
                  info.cwd.hasPrefix("/"), Self.directoryExists(info.cwd) else { continue }
            let key = SessionKey(providerID: "codex", sessionID: id.uuidString)
            if let previous = sessions[key], previous.modifiedAt >= modified {
                sessions[key]?.transcripts.append(file)
                continue
            }
            let line = info.title?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)
            let title = line.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) } ?? String(key.sessionID.prefix(8))
            sessions[key] = AgentSession(id: key, title: title, directory: URL(fileURLWithPath: info.cwd, isDirectory: true),
                                         modifiedAt: modified, transcripts: [file] + (sessions[key]?.transcripts ?? []))
        }
        return Array(sessions.values)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    public nonisolated func launch(for session: AgentSession) throws -> SessionLaunch {
        guard session.id.providerID == "codex", let id = UUID(uuidString: session.id.sessionID) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard Self.directoryExists(session.directory.path) else { throw CocoaError(.fileNoSuchFile) }
        guard !Self.runningSessions().contains(id) else {
            throw NSError(domain: "Seance.Codex", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This conversation is open in another Codex process."
            ])
        }
        return SessionLaunch(executable: "codex", arguments: ["resume", session.id.sessionID], directory: session.directory)
    }
}
