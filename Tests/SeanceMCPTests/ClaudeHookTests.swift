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
    for event in ["SessionStart", "SessionEnd"] {
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": event, "session_id": sessionID.uuidString,
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
    #expect(events == ["SessionStart", "SessionEnd"])
    #expect(store.selectedID == focused)
}
