import AppKit
import SeanceCore

@MainActor
final class UpdateChecker: NSObject {
    private var checking = false

    @objc func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            let alert = NSAlert()
            var releasePage: URL?
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            do {
                guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                    throw URLError(.cannotParseResponse)
                }
                let endpoint = URL(string: "https://api.github.com/repos/elmcrest/Seance/releases/latest")!
                var request = URLRequest(url: endpoint, timeoutInterval: 15)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Seance", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                let update: ReleaseUpdate
                switch (response as? HTTPURLResponse)?.statusCode {
                case 200: update = try ReleaseUpdate.evaluate(installed: installed, response: data)
                case 404: update = .unavailable
                case 403, 429:
                    throw UpdateError.requestLimited
                default: throw URLError(.badServerResponse)
                }
                switch update {
                case .current:
                    alert.messageText = "Seance is up to date"
                    alert.informativeText = "You’re running version " + installed + "."
                case .unavailable:
                    alert.messageText = "No update available for this Mac"
                    alert.informativeText = "GitHub has no newer stable download available for this build."
                case .newer(let version, let page):
                    alert.messageText = "Seance " + version + " is available"
                    alert.informativeText = "You’re running " + installed + ". Open the release notes to download the update."
                    alert.addButton(withTitle: "View Release")
                    releasePage = page
                }
            } catch {
                alert.messageText = "Couldn’t check for updates"
                alert.informativeText = error.localizedDescription
            }
            alert.addButton(withTitle: releasePage == nil ? "OK" : "Later")
            if alert.runModal() == .alertFirstButtonReturn, let releasePage {
                NSWorkspace.shared.open(releasePage)
            }
        }
    }
}

private enum UpdateError: LocalizedError {
    case requestLimited
    var errorDescription: String? { "GitHub declined the request. Please try again later." }
}
