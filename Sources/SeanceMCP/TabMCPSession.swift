import CoreFoundation
import Foundation
import SeanceCore

@MainActor
final class TabMCPSession {
    private typealias Object = [String: Any]
    private let store: TabStore
    private let caller: TabID?
    private var initialized = false

    init(store: TabStore, caller: TabID?) {
        self.store = store
        self.caller = caller
    }

    func handle(_ data: Data) -> Data? {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            return failure(-32700, "Parse error")
        }
        guard let request = object as? Object, request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else { return failure(-32600, "Invalid request") }
        guard let id = request["id"] else { return nil }
        let numericID = (id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
        guard id is String || numericID else {
            return failure(-32600, "Invalid request ID")
        }
        let params = request["params"] as? Object ?? [:]
        let result: Object
        switch method {
        case "initialize":
            guard !initialized, let requested = params["protocolVersion"] as? String else {
                return failure(-32602, "Expected initial protocol version", id)
            }
            initialized = true
            let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            result = ["protocolVersion": versions.contains(requested) ? requested : versions[0],
                      "capabilities": ["tools": [:]], "serverInfo": ["name": "seance", "version": "0.1.0"]]
        case "ping":
            result = [:]
        default:
            guard initialized else { return failure(-32002, "Initialize the connection first", id) }
            switch method {
            case "tools/list":
                result = ["tools": Self.tools]
            case "tools/call":
                guard let name = params["name"] as? String,
                      Self.tools.contains(where: { $0["name"] as? String == name }) else {
                    return failure(-32602, "Unknown or missing tool name", id)
                }
                guard let arguments = (params["arguments"] ?? Object()) as? Object else {
                    return failure(-32602, "Expected an arguments object", id)
                }
                result = call(name, arguments: arguments)
            default:
                return failure(-32601, "Method not found", id)
            }
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static let tools: [Object] = [
        tool("list_tabs", "List open tabs in sidebar order."),
        tool("get_current_tab", "Get the tab that launched this agent."),
        tool("rename_tab", "Rename a tab. Omit tab_id for the calling tab. Pass null to clear the override.",
             properties: ["tab_id": ["type": "string", "format": "uuid"], "title": ["type": ["string", "null"]]],
             required: ["title"]),
    ]

    private static func tool(_ name: String, _ description: String, properties: Object = [:],
                             required: [String] = []) -> Object {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required,
                         "additionalProperties": false] as Object]
    }

    private func call(_ name: String, arguments: Object) -> Object {
        let value: Any
        do {
            if name == "list_tabs" {
                guard arguments.isEmpty else { return toolError("list_tabs takes no arguments") }
                value = store.tabs.map(metadata)
            } else {
                guard let caller else { return toolError("Missing or invalid TAB_ID") }
                // Validate the caller even when a rename explicitly targets a different tab.
                let originatingTab = try store.tab(caller)
                if name == "get_current_tab" {
                    guard arguments.isEmpty else { return toolError("get_current_tab takes no arguments") }
                    value = metadata(originatingTab)
                } else {
                    guard Set(arguments.keys).isSubset(of: ["title", "tab_id"]),
                          let title = arguments["title"], title is String || title is NSNull else {
                        return toolError("Expected title as a string or null and an optional tab_id")
                    }
                    var target = caller
                    if let raw = arguments["tab_id"] {
                        guard let text = raw as? String, let uuid = UUID(uuidString: text)
                        else { return toolError("tab_id must be a UUID") }
                        target = TabID(uuid)
                    }
                    try store.rename(target, to: title as? String)
                    value = metadata(try store.tab(target))
                }
            }
        } catch TabStoreError.unknownTab(let id) {
            return toolError("Tab \(id.rawValue.uuidString) is no longer open")
        } catch {
            return toolError(error.localizedDescription)
        }
        return ["content": [["type": "text", "text": String(decoding: encode(value), as: UTF8.self)]]]
    }

    private func metadata(_ tab: Tab) -> Object {
        ["id": tab.id.rawValue.uuidString, "title": tab.title, "directory": tab.directory.path,
         "program_title": tab.programTitle as Any, "title_override": tab.titleOverride as Any,
         "selected": tab.id == store.selectedID]
    }

    private func toolError(_ message: String) -> Object {
        ["isError": true, "content": [["type": "text", "text": message]]]
    }

    private func failure(_ code: Int, _ message: String, _ id: Any = NSNull()) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as Object] as Object)
    }

    private func encode(_ object: Any) -> Data {
        // All output objects are constructed from JSON primitives or validated request IDs.
        try! JSONSerialization.data(withJSONObject: object)
    }
}
