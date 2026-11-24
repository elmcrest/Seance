import Foundation
import libzstd

/// Scans one session at a time off the main actor. No persistent copy of conversation text is kept.
public actor ConversationSearch {
    public init() {}

    public func contains(_ query: String, in session: AgentSession) throws -> Bool {
        var readError: Error?
        for file in session.transcripts {
            try Task.checkCancellation()
            do {
                if try scan(file, provider: session.id.providerID, query: query) { return true }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        return false
    }

    private nonisolated func scan(_ file: URL, provider: String, query: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let compressed = file.pathExtension == "zst"
        let decoder = compressed ? ZSTD_createDStream() : nil
        defer { if let decoder { ZSTD_freeDStream(decoder) } }
        if compressed, decoder == nil { throw CocoaError(.fileReadUnknown) }

        var pending = Data()
        func consume(_ bytes: UnsafeRawBufferPointer) throws -> Bool {
            var remaining = bytes[...]
            while let newline = remaining.firstIndex(of: 10) {
                try Task.checkCancellation()
                pending.append(contentsOf: remaining[..<newline])
                if Self.matches(pending, provider: provider, query: query) { return true }
                pending.removeAll(keepingCapacity: true)
                remaining = remaining[(newline + 1)...]
            }
            pending.append(contentsOf: remaining)
            return false
        }

        var output = [UInt8](repeating: 0, count: 128 * 1024)
        var frameRemaining = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            let found = try chunk.withUnsafeBytes { bytes -> Bool in
                guard let decoder else { return try consume(bytes) }
                var input = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
                return try output.withUnsafeMutableBytes { buffer in
                    repeat {
                        try Task.checkCancellation()
                        var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                        frameRemaining = ZSTD_decompressStream(decoder, &out, &input)
                        guard ZSTD_isError(frameRemaining) == 0 else { throw CocoaError(.fileReadCorruptFile) }
                        if try consume(UnsafeRawBufferPointer(rebasing: buffer[..<out.pos])) { return true }
                        if input.pos == input.size && out.pos < out.size { break }
                    } while input.pos < input.size || frameRemaining != 0
                    return false
                }
            }
            if found { return true }
        }
        guard frameRemaining == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return Self.matches(pending, provider: provider, query: query)
    }

    private static func matches(_ line: Data, provider: String, query: String) -> Bool {
        guard !line.isEmpty, let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        func matchesText(_ value: Any?) -> Bool {
            (value as? String)?.localizedStandardContains(query) == true
        }
        func matchesBlocks(_ value: Any?, types: Set<String>) -> Bool {
            guard let blocks = value as? [[String: Any]] else { return false }
            return blocks.contains { types.contains($0["type"] as? String ?? "") && matchesText($0["text"]) }
        }
        let type = row["type"] as? String
        if provider == "claude" {
            guard type == "user" || type == "assistant", row["isMeta"] as? Bool != true,
                  row["isSidechain"] as? Bool != true, let message = row["message"] as? [String: Any] else { return false }
            return matchesText(message["content"]) || matchesBlocks(message["content"], types: ["text"])
        }
        guard let payload = row["payload"] as? [String: Any] else { return false }
        if type == "event_msg", ["user_message", "agent_message"].contains(payload["type"] as? String ?? "") {
            return matchesText(payload["message"])
        }
        guard type == "response_item", payload["type"] as? String == "message",
              ["user", "assistant"].contains(payload["role"] as? String ?? "") else { return false }
        return matchesBlocks(payload["content"], types: ["input_text", "output_text", "text"])
    }
}
