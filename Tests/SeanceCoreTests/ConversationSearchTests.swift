import Foundation
import SeanceCore
import Testing

@Test func conversationSearchFindsMessageTextAcrossRollouts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let claude = root.appendingPathComponent("claude.jsonl")
    let codex = root.appendingPathComponent("codex.jsonl.zst")
    let earlier = root.appendingPathComponent("earlier.jsonl")
    try Data(#"{"type":"event_msg","payload":{"type":"user_message","message":"Initial question"}}"#.utf8).write(to: earlier)
    let rows: [[String: Any]] = [
        ["type": "user", "message": ["content": [["type": "tool_result", "content": "tool-only"]]]],
        ["type": "assistant", "message": ["content": [["type": "text", "text": String(repeating: "x", count: 70000) + " Later reply"]]]],
    ]
    let data = try rows.map { try JSONSerialization.data(withJSONObject: $0) }
    try (data[0] + Data([10]) + data[1]).write(to: claude)
    // Zstandard frame containing a Codex response_item with the text "Later reply".
    try Data(base64Encoded: "KLUv/QRYBQMAooYUGKApHQ2XQ5INpNwdLeeXNDF0oRkjgSNbAYAkISRNBo0CyDdBq6VH+MURPHKD6o9/rtDSH3samdaqzaGW+mCZPqoGO5MMW3r4RuE8h2nUqjG9iQMAKkJ9qvJUCvUE+CWrDA==")!.write(to: codex)
    let scanner = ConversationSearch()
    func session(_ provider: String, _ files: [URL]) -> AgentSession {
        AgentSession(id: SessionKey(providerID: provider, sessionID: UUID().uuidString),
                     title: "Metadata only", directory: root, modifiedAt: Date(), transcripts: files)
    }
    let c = session("claude", [claude])
    #expect(try await scanner.contains("later REPLY", in: c))
    #expect(try await !scanner.contains("tool-only", in: c))
    let x = session("codex", [earlier, codex])
    #expect(try await scanner.contains("later REPLY", in: x))
    #expect(try await scanner.contains("initial question", in: x))
    #expect(try await !scanner.contains("Metadata only", in: x))
    try Data([1, 2, 3]).write(to: codex)
    await #expect(throws: CocoaError.self) { try await scanner.contains("missing", in: x) }
}
