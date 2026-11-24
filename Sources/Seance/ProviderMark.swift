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

    private static let marks: [String: NSImage] = {
        var marks: [String: NSImage] = [:]
        for provider in ["claude", "codex"] {
            if let url = Bundle.main.url(forResource: provider, withExtension: "svg", subdirectory: "AgentIcons"),
               let image = NSImage(contentsOf: url) { marks[provider] = image }
        }
        return marks
    }()

    var body: some View {
        Group {
            if let image = Self.marks[provider] {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(provider == "claude" ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary)
            } else {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
            }
        }
        .help(Self.name(for: provider))
        .accessibilityLabel(Self.name(for: provider))
    }
}
