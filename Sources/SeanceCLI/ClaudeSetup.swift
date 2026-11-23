import Foundation

// Read the registration for idempotence. Claude Code's own CLI writes and locks the file.
func claudeAlreadyConfigured(helper: String) throws -> Bool {
    let env = ProcessInfo.processInfo.environment
    let directory = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    let url = directory.appendingPathComponent(".claude.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let servers = config?["mcpServers"] as? [String: Any]
    let entry = servers?["seance"] as? [String: Any]
    let environment = entry?["env"] as? [String: String]
    return entry?["command"] as? String == helper && entry?["args"] as? [String] == ["mcp"]
        && environment?["TAB_ID"] == "${TAB_ID:-}"
        && environment?["SEANCE_SOCKET_PATH"] == "${SEANCE_SOCKET_PATH:-}"
}
