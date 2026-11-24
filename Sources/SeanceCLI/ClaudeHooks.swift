import Darwin
import Foundation
import SeanceIPC

private struct ClaudeHookInput: Decodable {
    let hook_event_name: ClaudeHookKind
    let session_id: UUID
    let tool_name: String?
}

func relayClaudeHook() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["SEANCE_SOCKET_PATH"],
          let tabID = env["TAB_ID"].flatMap(UUID.init(uuidString:)) else { return }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let event = try JSONDecoder().decode(ClaudeHookInput.self, from: input)
    if event.hook_event_name == .question && event.tool_name != "AskUserQuestion" { return }
    let payload = ClaudeHook(kind: event.hook_event_name, sessionID: event.session_id, tabID: tabID)
    let fd = try LocalSocket.open(path: path, listening: false)
    defer { Darwin.close(fd) }
    try writeLine(Data(ClaudeHook.header.utf8), to: fd)
    try writeLine(JSONEncoder().encode(payload), to: fd)
    var reader = LineReader(fd)
    guard try reader.next() == Data("ok".utf8) else {
        throw IPCError.message("Seance could not apply the Claude session hook")
    }
}

/// Keep the command identical when the app moves. Each surface supplies the current helper path.
func installClaudeHooks() throws {
    let env = ProcessInfo.processInfo.environment
    let root = env["CLAUDE_CONFIG_DIR"].flatMap { value in
        value.isEmpty ? nil : URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("settings.json").resolvingSymlinksInPath()
    var settings: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: file.path) {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw IPCError.message("Expected an object in Claude settings at " + file.path)
        }
        settings = object
    }
    let command = #"/bin/sh -c 'if [ -n "$SEANCE_SOCKET_PATH" ] && [ -x "$SEANCE_HELPER" ]; then exec "$SEANCE_HELPER" claude-hook; fi'"#
    guard var hooks = (settings["hooks"] ?? [:]) as? [String: Any] else {
        throw IPCError.message("Expected an object in Claude settings.hooks")
    }
    var changed = false
    for kind in [ClaudeHookKind.start, .end, .permission, .question, .elicitation] {
        let matcher: String? = kind == .question ? "AskUserQuestion" : nil
        guard var groups = (hooks[kind.rawValue] ?? []) as? [[String: Any]] else {
            throw IPCError.message("Expected an array in Claude hooks." + kind.rawValue)
        }
        let registered = groups.contains { group in
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            return group["matcher"] as? String == matcher && handlers.contains { $0["command"] as? String == command }
        }
        if !registered {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            group["matcher"] = matcher
            groups.append(group)
            hooks[kind.rawValue] = groups
            changed = true
        }
    }
    if changed {
        settings["hooks"] = hooks
        var document = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        document.append(10)
        try document.write(to: file, options: .atomic)
    }
}
