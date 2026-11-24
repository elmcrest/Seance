import SeanceCore
import Testing

@MainActor
@Test func inputAlertsAreScopedToPromptAndTab() {
    let a = TabID(), b = TabID(), attention = AgentAttention()
    let now = ContinuousClock.now
    #expect(attention.shouldPlay(for: a, at: now))
    #expect(!attention.shouldPlay(for: a, at: now + .milliseconds(25)))
    #expect(attention.shouldPlay(for: b, at: now))
    #expect(attention.shouldPlay(for: a, at: now + .seconds(2)))
    #expect(AgentAttention.isCodexPrompt(title: "Codex", body: "Approval requested: run tests", providers: []))
    #expect(AgentAttention.isCodexPrompt(title: "", body: "Question: Which branch?", providers: ["codex"]))
    #expect(!AgentAttention.isCodexPrompt(title: "", body: "Question: Which branch?", providers: []))
    #expect(!AgentAttention.isCodexPrompt(title: "Codex", body: "I finished the task.", providers: ["codex"]))
}
