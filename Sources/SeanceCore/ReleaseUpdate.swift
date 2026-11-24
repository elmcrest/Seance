import Foundation

public enum ReleaseUpdate: Equatable, Sendable {
    case current
    case unavailable
    case newer(version: String, page: URL)

    public static func evaluate(installed: String, response: Data) throws -> Self {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let state: String }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }

        func components(_ version: String) throws -> [Int] {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw URLError(.cannotParseResponse) }
            return try parts.map { part in
                guard let number = Int(part), number >= 0, String(number) == part else {
                    throw URLError(.cannotParseResponse)
                }
                return number
            }
        }

        let release = try JSONDecoder().decode(Release.self, from: response)
        guard !release.draft, !release.prerelease else { return .unavailable }
        let tag = release.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let remote = try components(version)
        guard try components(installed).lexicographicallyPrecedes(remote) else { return .current }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let filename = "Seance-\(version)-macOS-\(architecture).zip"
        guard release.assets.contains(where: { $0.name == filename && $0.state == "uploaded" }) else {
            return .unavailable
        }
        return .newer(version: version, page: URL(string: "https://github.com/elmcrest/Seance/releases/tag/\(tag)")!)
    }
}
