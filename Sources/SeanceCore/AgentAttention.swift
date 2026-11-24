import Foundation

@MainActor
public final class AgentAttention {
    private var recent: [TabID: ContinuousClock.Instant] = [:]

    public init() {}

    /// Multiple hook events can describe one prompt. Independent tabs still sound independently.
    public func shouldPlay(for tab: TabID, at now: ContinuousClock.Instant = .now) -> Bool {
        recent = recent.filter { now - $0.value < .seconds(2) }
        guard recent[tab] == nil else { return false }
        recent[tab] = now
        return true
    }

    // OSC 777 names its sender. OSC 9 sends only the display text, so check
    // the originating tab before interpreting the Codex TUI's prompt prefixes.
    public static func isCodexPrompt(title: String, body: String, providers: [String]) -> Bool {
        guard title == "Codex" || providers.contains("codex") else { return false }
        return ["Approval requested: ", "Approval requested by ", "Codex wants to edit ",
                "Plan mode prompt: ", "Question: "].contains(where: body.hasPrefix)
    }
}
