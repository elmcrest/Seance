import Foundation
import Testing
import SeanceCore
@testable import SeanceMCP

private typealias Object = [String: Any]
private func json(_ value: Object) throws -> Data {
    try JSONSerialization.data(withJSONObject: value)
}
private func request(_ id: Int, _ method: String, _ params: Object = [:]) throws -> Data {
    try json(["jsonrpc": "2.0", "method": method, "id": id, "params": params])
}
private let protocolVersion = "2025-06-18"

@MainActor
@Test func rejectsLateCallerEvenWithExplicitTarget() throws {
    let store = TabStore()
    let a = store.open(directory: URL(fileURLWithPath: "/tmp/a"))
    let b = store.open(directory: URL(fileURLWithPath: "/tmp/b"))
    let server = TabMCPSession(store: store, caller: a)
    _ = try server.handle(request(1, "initialize", ["protocolVersion": protocolVersion]))
    try store.close(a)
    let rename = try request(2, "tools/call", ["name": "rename_tab", "arguments": [
        "tab_id": b.rawValue.uuidString, "title": "Wrong"]])
    let data = try #require(server.handle(rename))
    let result = try #require((JSONSerialization.jsonObject(with: data) as? Object)?["result"] as? Object)
    #expect(result["isError"] as? Bool == true)
    #expect(try store.tab(b).titleOverride == nil)
}

private final class TestBundleAnchor: NSObject {}

// Use the executable the client would launch. Run blocking pipe IO off the main actor
// so the app's real accept loop and main-actor store keep receiving requests.
@MainActor
@Test func stdioBridgeRoutesBackgroundCaller() async throws {
    let store = TabStore()
    let a = store.open(directory: URL(fileURLWithPath: "/tmp/a"))
    let b = store.open(directory: URL(fileURLWithPath: "/tmp/b"))
    let server = try TabMCPServer(store: store, socketPath: nil)
    try server.start()
    defer { server.stop() }

    var frames = [
        try request(1, "initialize", ["protocolVersion": protocolVersion]),
        try json(["jsonrpc": "2.0", "method": "notifications/initialized"]),
        try request(2, "tools/list"),
        try request(3, "tools/call", ["name": "list_tabs"]),
        try request(4, "tools/call", ["name": "get_current_tab"]),
        try request(5, "tools/call", ["name": "rename_tab", "arguments": ["title": "Build"]]),
    ]
    frames.append(try request(6, "tools/call", ["name": "rename_tab", "arguments": ["title": NSNull()]]))
    let input = frames.reduce(into: Data()) { $0.append($1); $0.append(10) }
    let path = server.socketPath
    let helper = Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("SeanceCLI")
    let responses = try await Task.detached {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["mcp"]
        process.environment = ["SEANCE_SOCKET_PATH": path, "TAB_ID": a.rawValue.uuidString]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }.value
    let replies = try responses.split(separator: 10).map {
        try #require(JSONSerialization.jsonObject(with: Data($0)) as? Object)
    }
    #expect(replies.compactMap { $0["id"] as? Int } == [1, 2, 3, 4, 5, 6])
    let results = try replies.map { try #require($0["result"] as? Object) }
    #expect(results[0]["protocolVersion"] as? String == protocolVersion)
    let tools = try #require(results[1]["tools"] as? [Object])
    #expect(tools.compactMap { $0["name"] as? String } == ["list_tabs", "get_current_tab", "rename_tab"])
    func content(_ index: Int) throws -> Any {
        let text = try #require((results[index]["content"] as? [Object])?.first?["text"] as? String)
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }
    let tabs = try #require(content(2) as? [Object])
    #expect(tabs.compactMap { $0["id"] as? String } == [a, b].map(\.rawValue.uuidString))
    #expect(try (content(3) as? Object)?["id"] as? String == a.rawValue.uuidString)
    #expect(try (content(4) as? Object)?["title"] as? String == "Build")
    #expect(try (content(5) as? Object)?["title"] as? String == "a")
    #expect(store.selectedID == b)
    #expect(try store.tab(b).title == "b")
}

@MainActor
@Test func duplicateListenerLeavesOriginalSocketIntact() throws {
    let store = TabStore()
    let server = try TabMCPServer(store: store, socketPath: nil)
    try server.start()
    defer { server.stop() }
    let second = try TabMCPServer(store: store, socketPath: server.socketPath)
    #expect(throws: POSIXError.self) { try second.start() }
    second.stop()
    #expect(FileManager.default.fileExists(atPath: server.socketPath))
}

@MainActor
@Test func missingCallerCannotRenameSelectedTab() throws {
    let store = TabStore()
    let selected = store.open(directory: URL(fileURLWithPath: "/tmp/selected"))
    let session = TabMCPSession(store: store, caller: nil)
    _ = try session.handle(request(1, "initialize", ["protocolVersion": protocolVersion]))
    for (name, args) in [("get_current_tab", [:]), ("rename_tab", ["title": "Wrong"])] {
        let req = try request(2, "tools/call", ["name": name, "arguments": args])
        let data = try #require(session.handle(req))
        let result = try #require((JSONSerialization.jsonObject(with: data) as? Object)?["result"] as? Object)
        #expect(result["isError"] as? Bool == true)
    }
    #expect(try store.tab(selected).titleOverride == nil)
}
