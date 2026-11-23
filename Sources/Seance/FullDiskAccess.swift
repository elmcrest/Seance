import AppKit
import Darwin

@MainActor
enum FullDiskAccess {
    private static let offeredKey = "didOfferFullDiskAccess"

    private enum Probe {
        case readable, restricted, unknown
    }

    private static func check() -> Probe {
        // macOS exposes no public FDA status API. Test only whether a protected
        // file opens. Never read its contents or query the permissions database.
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        return errno == EPERM ? .restricted : .unknown
    }

    static func present(in window: NSWindow, atLaunch: Bool = false) {
        guard window.attachedSheet == nil else { return }
        if atLaunch && UserDefaults.standard.bool(forKey: offeredKey) { return }
        let status = check()
        if atLaunch && status != .restricted { return }

        let alert = NSAlert()
        switch status {
        case .restricted:
            alert.messageText = "Allow Full Disk Access for Seance?"
            alert.informativeText = "macOS blocked a protected-file check. Full Disk Access lets shells and agents running in Seance access protected files. You can continue using Seance with your current permissions."
        case .readable:
            alert.messageText = "Seance can open the protected test file"
            alert.informativeText = "To verify or change the Full Disk Access switch for Seance, open Privacy & Security in System Settings."
        case .unknown:
            alert.messageText = "Check Full Disk Access in System Settings"
            alert.informativeText = "Seance couldn’t determine access from its protected-file check. You can review the switch under Privacy & Security."
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: atLaunch ? "Not Now" : "Close")
        if atLaunch { UserDefaults.standard.set(true, forKey: offeredKey) }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            if !NSWorkspace.shared.open(url) {
                let fallback = NSAlert()
                fallback.messageText = "Open System Settings → Privacy & Security → Full Disk Access"
                fallback.informativeText = "To enable access, add the Seance app selected in Finder."
                fallback.beginSheetModal(for: window)
            }
        }
    }
}
