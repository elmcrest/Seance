import Foundation

public enum ClaudeHookKind: String, Codable, Sendable {
    case start = "SessionStart"
    case end = "SessionEnd"
}

package struct ClaudeHook: Codable, Sendable {
    package static let header = "seance-claude-hook-v1"

    package let kind: ClaudeHookKind
    package let sessionID: UUID
    package let tabID: UUID

    package init(kind: ClaudeHookKind, sessionID: UUID, tabID: UUID) {
        self.kind = kind
        self.sessionID = sessionID
        self.tabID = tabID
    }
}
