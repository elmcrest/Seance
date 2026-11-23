import Darwin
import Foundation
import SeanceIPC

func configureClaude(helper: String) throws {
    let env = ProcessInfo.processInfo.environment
    let directory = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        throw IPCError.message("Another setup is using the Claude configuration directory.")
    }
    let config = directory.appendingPathComponent(".claude.json")
    let backup = directory.appendingPathComponent(".seance-mcp-migration.json")
    let environment = ["TAB_ID": "${TAB_ID:-}", "SEANCE_SOCKET_PATH": "${SEANCE_SOCKET_PATH:-}"]
    let desired: [String: Any] = ["type": "stdio", "command": helper, "args": ["mcp"], "env": environment]

    func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "mcp"] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IPCError.message("Claude Code MCP setup failed") }
    }
    func add(_ entry: Data) throws {
        try run(["add-json", "--scope", "user", "seance", String(decoding: entry, as: UTF8.self)])
    }

    var entry: [String: Any]?
    if FileManager.default.fileExists(atPath: config.path) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        entry = (object?["mcpServers"] as? [String: Any])?["seance"] as? [String: Any]
    }
    if let entry {
        guard let command = entry["command"] as? String,
              command == helper || command.hasSuffix("/Contents/Helpers/seance"),
              entry["args"] as? [String] == ["mcp"],
              entry["env"] as? [String: String] == environment,
              (entry["type"] as? String ?? "stdio") == "stdio",
              Set(entry.keys).isSubset(of: Set(desired.keys)) else {
            throw IPCError.message("A custom user MCP server named seance already exists in Claude Code.")
        }
        if command == helper {
            try installClaudeHooks()
            try? FileManager.default.removeItem(at: backup)
            print("Seance is already configured for Claude Code")
            return
        }
        // Keep the original entry across interruption between the two Claude CLI calls.
        let previous = try JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
        if FileManager.default.fileExists(atPath: backup.path) {
            guard try Data(contentsOf: backup) == previous else {
                throw IPCError.message("An earlier Seance registration is saved at " + backup.path)
            }
        } else {
            try previous.write(to: backup, options: .withoutOverwriting)
        }
        try run(["remove", "--scope", "user", "seance"])
    }
    do {
        try add(JSONSerialization.data(withJSONObject: desired))
    } catch {
        if FileManager.default.fileExists(atPath: backup.path) {
            do { try add(Data(contentsOf: backup)) }
            catch { throw IPCError.message("Claude MCP setup failed. The previous registration is saved at " + backup.path) }
            try FileManager.default.removeItem(at: backup)
        }
        throw error
    }
    try? FileManager.default.removeItem(at: backup)
    try installClaudeHooks()
}
