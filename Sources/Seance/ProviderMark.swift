import SwiftUI

struct ProviderMark: View {
    let provider: String

    static func name(for provider: String) -> String {
        switch provider {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: provider
        }
    }

    var body: some View {
        Group {
            switch provider {
            case "claude": Image(systemName: "sun.max.fill").foregroundStyle(.orange)
            case "codex": Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.blue)
            default: Image(systemName: "text.bubble").foregroundStyle(.secondary)
            }
        }
        .help(Self.name(for: provider))
        .accessibilityLabel(Self.name(for: provider))
    }
}
