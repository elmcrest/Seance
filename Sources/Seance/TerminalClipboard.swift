import AppKit

@MainActor
final class TerminalClipboard {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("seance-paste-" + UUID().uuidString, isDirectory: true)
    private var cachedImage: (change: Int, url: URL)?

    func text(for board: NSPasteboard) throws -> String? {
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            return files.map { Self.quote($0.path) }.joined(separator: " ")
        }
        if let text = board.string(forType: .string), !text.isEmpty { return text }
        if let cachedImage, cachedImage.change == board.changeCount,
           FileManager.default.fileExists(atPath: cachedImage.url.path) { return Self.quote(cachedImage.url.path) }
        let png: Data
        if let data = board.data(forType: .png) {
            png = data
        } else {
            guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            png = data
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: file, options: .atomic)
        cachedImage = (board.changeCount, file)
        return Self.quote(file.path)
    }

    private static func quote(_ path: String) -> String {
        if path.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || "/._-".utf8.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
