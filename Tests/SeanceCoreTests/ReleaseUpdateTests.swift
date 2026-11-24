import Foundation
import Testing
import SeanceCore

@Test func checksStableReleaseVersionsAndDownloads() throws {
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif
    func check(_ tag: String, installed: String = "0.9.0", asset: String? = nil,
               prerelease: Bool = false, draft: Bool = false) throws -> ReleaseUpdate {
        let assets = asset.map { [["name": $0, "state": "uploaded"]] } ?? []
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "prerelease": prerelease, "draft": draft, "assets": assets
        ])
        return try ReleaseUpdate.evaluate(installed: installed, response: data)
    }
    #expect(try check("v0.10.0", asset: "Seance-0.10.0-macOS-\(arch).zip") ==
            .newer(version: "0.10.0", page: URL(string: "https://github.com/elmcrest/Seance/releases/tag/v0.10.0")!))
    #expect(try check("v0.9.0") == .current)
    #expect(try check("v0.8.2") == .current)
    #expect(try check("v1.0.0") == .unavailable)
    #expect(try check("v1.0.0", asset: "source.zip") == .unavailable)
    #expect(try check("v1.0.0", prerelease: true) == .unavailable)
    #expect(try check("v1.0.0", draft: true) == .unavailable)
    #expect(throws: URLError.self) { try check("v1.bad.0") }
}
