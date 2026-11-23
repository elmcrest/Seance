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
        try configureClaude(helper: executable)
    case "codex":
        try configureCodex(helper: executable)
    default:
        throw IPCError.message("Expected claude or codex")
    }
}

do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["claude-hook"]: try relayClaudeHook()
    case ["run-resume"]: try runResume()
    case ["mcp"]: try relay()
    case ["setup", "claude"]: try setup("claude")
    case ["setup", "codex"]: try setup("codex")
    default: throw IPCError.message("Usage: seance mcp | seance setup <claude|codex>")
    }
} catch {
    FileHandle.standardError.write(Data(("seance: " + error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
