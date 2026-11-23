import Foundation
import SeanceIPC

// Codex's config writer supports env_vars (forwarded names), unlike the fixed
// --env values accepted by 'codex mcp add'. Change only this server's config.
func configureCodex(helper: String) throws {
    let process = Process()
    let input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["codex", "app-server"]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    let writer = input.fileHandleForWriting.fileDescriptor
    var reader = LineReader(output.fileHandleForReading.fileDescriptor)
    func send(_ object: [String: Any]) throws {
        try writeLine(JSONSerialization.data(withJSONObject: object), to: writer)
    }
    func awaitReply(_ id: Int) throws {
        while let line = try reader.next() {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["id"] as? Int == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw IPCError.message(error["message"] as? String ?? "Codex rejected the configuration")
            }
            guard object["result"] != nil else { throw IPCError.message("Invalid Codex response") }
            return
        }
        throw IPCError.message("Codex exited before acknowledging the configuration")
    }
    try send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "seance", "version": "0.1.0"]]])
    try awaitReply(1)
    try send(["method": "initialized"])
    try send(["method": "config/value/write", "id": 2, "params": [
        "keyPath": "mcp_servers.seance", "mergeStrategy": "upsert",
        "value": ["command": helper, "args": ["mcp"], "env_vars": ["TAB_ID", "SEANCE_SOCKET_PATH"]] as [String: Any],
    ] as [String: Any]])
    try awaitReply(2)
    print("Configured Seance for Codex")
}
