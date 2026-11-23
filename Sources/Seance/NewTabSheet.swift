import AppKit
import SeanceCore
import SwiftUI

@MainActor
func presentNewTabPicker(
    in window: NSWindow,
    attachments: SessionAttachments,
    newTerminal: @escaping () -> Void,
    resume: @escaping (AgentSession, SessionLaunch) -> Void
) {
    guard window.attachedSheet == nil else { return }
    let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    panel.title = "New Tab"
    func dismiss() {
        window.endSheet(panel)
    }
    let picker = NewTabPicker(
        provider: ClaudeSessionProvider(),
        attachments: attachments,
        onNewTerminal: {
            dismiss()
            newTerminal()
        },
        onResume: { session, launch in
            dismiss()
            resume(session, launch)
        },
        onCancel: dismiss
    )
    let host = NSHostingController(rootView: picker)
    panel.contentViewController = host
    panel.setContentSize(host.view.fittingSize)
    window.beginSheet(panel) { _ in
        panel.orderOut(nil)
        panel.contentViewController = nil
    }
}
