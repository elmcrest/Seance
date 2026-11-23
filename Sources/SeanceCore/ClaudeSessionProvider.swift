import Foundation

public actor ClaudeSessionProvider: AgentSessionProvider {
    private let projectsDirectory: URL

    public init(configDirectory: URL? = nil) {
        let config = configDirectory ?? Self.defaultConfigDirectory()
        projectsDirectory = config.appendingPathComponent("projects", isDirectory: true)
    }

    private static func defaultConfigDirectory() -> URL {
        if let value = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    public func listSessions() async throws -> [AgentSession] {
        let files = FileManager.default
        let projects: [URL]
        do {
            projects = try files.contentsOfDirectory(at: projectsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        var sessions: [SessionKey: AgentSession] = [:]
        for project in projects.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let transcripts = try? files.contentsOfDirectory(at: project,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else { continue }
            let index = legacyIndex(in: project)
            for transcript in transcripts where transcript.pathExtension == "jsonl" {
                try Task.checkCancellation()
                let name = transcript.deletingPathExtension().lastPathComponent
                guard let uuid = UUID(uuidString: name),
                      let info = try? transcript.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      info.isRegularFile == true, let modified = info.contentModificationDate,
                      let session = readTranscript(transcript, uuid: uuid, modified: modified, hint: index[uuid]) else {
                    continue
                }
                if let existing = sessions[session.id], existing.modifiedAt >= modified { continue }
                sessions[session.id] = session
            }
        }
        return sessions.values.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id.sessionID < $1.id.sessionID
        }
    }

    public nonisolated func launch(for session: AgentSession) throws -> SessionLaunch {
        guard session.id.providerID == "claude", UUID(uuidString: session.id.sessionID) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard Self.directoryExists(session.directory) else { throw CocoaError(.fileNoSuchFile) }
        return SessionLaunch(executable: "claude", arguments: ["--resume", session.id.sessionID], directory: session.directory)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    // Older clients also keep a partial index. Its projectPath is useful when a
    // transcript's first record exceeds the preview window. A transcript is still
    // required so removed sessions never reappear from a stale index.
    private func legacyIndex(in project: URL) -> [UUID: [String: Any]] {
        let url = project.appendingPathComponent("sessions-index.json")
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = index["entries"] as? [[String: Any]] else { return [:] }
        var result: [UUID: [String: Any]] = [:]
        for entry in entries {
            if let id = entry["sessionId"] as? String, let uuid = UUID(uuidString: id) {
                result[uuid] = entry
            }
        }
        return result
    }

    private func readTranscript(_ url: URL, uuid: UUID, modified: Date, hint: [String: Any]?) -> AgentSession? {
        guard hint?["isSidechain"] as? Bool != true, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // As in Anthropic's local session lister, preview the head and tail.
        // Do not load an entire conversation just to show the picker.
        let window = 128 * 1024
        guard let length = try? handle.seekToEnd(), length > 0,
              (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: window) else { return nil }
        var data = head
        if length > UInt64(window) {
            let start = max(UInt64(window), length - UInt64(window))
            guard (try? handle.seek(toOffset: start)) != nil,
                  let tail = try? handle.read(upToCount: window) else { return nil }
            if start > UInt64(window) { data.append(0x0a) }
            data.append(tail)
        }
        var cwd: String?
        var customTitle: String?
        var generatedTitle: String?
        var summary: String?
        var firstPrompt: String?
        var sawMainRecord = false
        for line in data.split(separator: 0x0a) {
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard row["isSidechain"] as? Bool != true else { continue }
            if let rowID = row["sessionId"] as? String, UUID(uuidString: rowID) != uuid { continue }
            if let path = row["cwd"] as? String, path.hasPrefix("/") { cwd = cwd ?? path }
            switch row["type"] as? String {
            case "user", "assistant":
                sawMainRecord = true
                if firstPrompt == nil, row["type"] as? String == "user", row["isMeta"] as? Bool != true,
                   let message = row["message"] as? [String: Any] {
                    if let content = message["content"] as? String {
                        firstPrompt = Self.preview(content)
                    } else if let blocks = message["content"] as? [[String: Any]] {
                        let first = blocks.first { $0["type"] as? String == "text" }
                        firstPrompt = Self.preview(first?["text"] as? String)
                    }
                }
            case "custom-title": customTitle = Self.preview(row["customTitle"] as? String)
            case "ai-title": generatedTitle = Self.preview(row["aiTitle"] as? String)
            case "summary": summary = Self.preview(row["summary"] as? String)
            default: break
            }
        }
        guard sawMainRecord || hint != nil,
              let path = cwd ?? hint?["projectPath"] as? String, path.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard Self.directoryExists(directory) else { return nil }
        let key = SessionKey(providerID: "claude", sessionID: uuid.uuidString)
        let indexedTitle = Self.preview(hint?["summary"] as? String)
        let prompt = firstPrompt ?? Self.preview(hint?["firstPrompt"] as? String)
        let title = customTitle ?? generatedTitle ?? summary ?? indexedTitle ?? prompt ?? String(key.sessionID.prefix(8))
        return AgentSession(id: key, title: title, directory: directory, modifiedAt: modified)
    }

    private static func preview(_ text: String?) -> String? {
        guard let text, let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let result = line.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : String(result.prefix(160))
    }
}
