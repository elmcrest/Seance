import Foundation
import SeanceCore
import SeanceMCP
import Testing

private final class BundleMarker: NSObject {}

@MainActor
@Test func claudeHooksFollowTheirOriginatingTab() async throws {
    let store = TabStore()
    let origin = store.open(directory: URL(filePath: "/tmp/a"))
    let focused = store.open(directory: URL(filePath: "/tmp/b"))
    let server = try TabMCPServer(store: store, socketPath: nil)
    var events: [String] = []
    let sessionID = UUID()
    server.onClaudeHook = { kind, tab, session in
        #expect(tab == origin)
        #expect(session == sessionID)
        events.append(kind.rawValue)
    }
    try server.start()
    defer { server.stop() }

    let helper = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("SeanceCLI")
    let environment = ["SEANCE_SOCKET_PATH": server.socketPath, "TAB_ID": origin.rawValue.uuidString]
    for (event, tool) in [("SessionStart", ""), ("PreToolUse", "Bash"), ("PermissionRequest", "Bash"),
                          ("PreToolUse", "AskUserQuestion"), ("Elicitation", ""), ("SessionEnd", "")] {
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": event, "session_id": sessionID.uuidString, "tool_name": tool,
            "transcript_path": "/tmp/transcript.jsonl",
        ])
        let status = try await Task.detached {
            let process = Process()
            let stdin = Pipe()
            process.executableURL = helper
            process.arguments = ["claude-hook"]
            process.environment = environment
            process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: payload)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        #expect(status == 0)
    }
    #expect(events == ["SessionStart", "PermissionRequest", "PreToolUse", "Elicitation", "SessionEnd"])
    #expect(store.selectedID == focused)
}

@MainActor
@Test func claudeSessionEndsWhenItsAgentExitsWithoutAHook() async throws {
    let store = TabStore()
    let tab = store.open(directory: URL(filePath: "/tmp/a"))
    let server = try TabMCPServer(store: store, socketPath: nil)
    var events: [String] = []
    server.onClaudeHook = { kind, _, _ in events.append(kind.rawValue) }
    try server.start()
    defer { server.stop() }

    let helper = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("SeanceCLI")
    let payload = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "SessionStart", "session_id": UUID().uuidString,
    ]).write(to: payload)
    defer { try? FileManager.default.removeItem(at: payload) }

    // Perl stands in for the agent: it runs the hook through a shell, then stays alive.
    let agent = Process()
    let stdin = Pipe()
    agent.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    agent.arguments = ["-e", "system($ENV{HOOK}); <STDIN>;"]
    agent.environment = [
        "SEANCE_SOCKET_PATH": server.socketPath, "TAB_ID": tab.rawValue.uuidString,
        "HOOK": "'\(helper.path)' claude-hook < '\(payload.path)'",
    ]
    agent.standardInput = stdin
    try agent.run()
    func wait(for count: Int) async throws {
        for _ in 0..<200 where events.count < count { try await Task.sleep(for: .milliseconds(25)) }
    }
    try await wait(for: 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(events == ["SessionStart"])

    try stdin.fileHandleForWriting.close()
    try await wait(for: 2)
    #expect(events == ["SessionStart", "SessionEnd"])
}
