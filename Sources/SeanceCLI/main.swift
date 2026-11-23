import Darwin
import Foundation
import SeanceIPC

private func relay() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["SEANCE_SOCKET_PATH"], !path.isEmpty else {
        throw IPCError.message("Launch this agent inside a Seance tab (SEANCE_SOCKET_PATH is unset)")
    }
    let fd = try LocalSocket.open(path: path, listening: false)
    defer { Darwin.close(fd) }
    // Only a normalized UUID can enter the line-framed identity header.
    let caller = env["TAB_ID"].flatMap(UUID.init(uuidString:))?.uuidString ?? ""
    try writeLine(Data(caller.utf8), to: fd)
    var input = LineReader(STDIN_FILENO)
    var responses = LineReader(fd)
    while let request = try input.next() {
        try writeLine(request, to: fd)
        guard let reply = try responses.next() else { throw IPCError.message("Seance closed the connection") }
        if !reply.isEmpty { try writeLine(reply, to: STDOUT_FILENO) }
    }
}

private func setup(_ client: String) throws {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
        throw IPCError.message("Cannot locate the Seance helper")
    }
    switch client {
    case "claude":
        try installClaudeHooks()
        if try claudeAlreadyConfigured(helper: executable) {
            print("Seance is already configured for Claude Code")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Resolve the tab environment on every client launch, including clients that
        // sanitize their child environment. Keep the expressions literal during setup.
        process.arguments = ["claude", "mcp", "add", "--scope", "user", "seance",
                             "-e", "TAB_ID=${TAB_ID:-}", "-e", "SEANCE_SOCKET_PATH=${SEANCE_SOCKET_PATH:-}",
                             "--", executable, "mcp"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IPCError.message("Claude Code setup failed") }
    case "codex":
        try configureCodex(helper: executable)
    default:
        throw IPCError.message("Expected claude or codex")
    }
}

do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["claude-hook"]: try relayClaudeHook()
    case ["mcp"]: try relay()
    case ["setup", "claude"]: try setup("claude")
    case ["setup", "codex"]: try setup("codex")
    default: throw IPCError.message("Usage: seance mcp | seance setup <claude|codex>")
    }
} catch {
    FileHandle.standardError.write(Data(("seance: " + error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
