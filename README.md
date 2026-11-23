# Seance

Seance is a macOS terminal for working with agent sessions. The foundation opens an AppKit window with two selectable sample tabs in a SwiftUI sidebar and a placeholder for the terminal surface.

Seance is MIT licensed. No telemetry, accounts, or upsells.

## Run locally

Use macOS 14 or later and an Xcode toolchain with Swift 6. Run these commands from the checkout.

```sh
swift test
./scripts/build-app
open -n .build/Seance.app
```

Open Package.swift in Xcode to develop the executable or the shared SeanceCore library. SwiftPM build products and the development app bundle live under the current worktree’s .build directory.

## Parallel development

The main checkout is for integration. Start each worker in its assigned sibling directory. Each branch starts at the shared foundation commit.

| Worktree | Branch | First deliverable |
|---|---|---|
| ../seance-terminal | feat/ghostty-terminal | Build full libghostty from Ghostty v1.2.3 at commit 6d2dd585a5d87fa745d48188dd096ca6e63014d0. Own the Swift wrapper, terminal view, bundling, and app composition. |
| ../seance-sidebar | feat/sidebar | Develop the SwiftUI sidebar against TabStore. Support rename, search, close, reorder, and keyboard switching. |
| ../seance-mcp | feat/mcp | Implement the in-process server and stdio helper for list_tabs, get_current_tab, and rename_tab. Supply one-line setup for Claude Code and Codex. |

Coordinate package manifest changes in the main checkout. When testing concurrent MCP builds, give each app and its helper the same explicit worktree-specific socket path. For Xcode command-line builds, pass a worktree-local Derived Data path.

TabStore owns ordered tab metadata and selection on the main actor. Create the tab before creating its surface and pass the UUID string as TAB_ID. Route program titles, directory changes, and agent requests by the originating tab ID. Both sidebar and MCP renames use the same sticky override. Clearing it reveals the latest program title, with the directory basename as fallback. Keep surfaces alive across sidebar selection and filtering.

The first integration check uses two real tabs. Focus B, change the title from A, and verify that only A changes and its shell remains running. Repeat through MCP and reject a late request after A closes.

## V1 scope

The terminal will read Ghostty’s configuration for fonts, themes, and keybindings. The new-tab picker will offer a fresh terminal followed by resumable Claude Code sessions, tracked by provider and session ID. A provider interface will leave room for Codex. Agent hooks will associate manually started sessions with open tabs.

Resuming reopens an agent conversation in a new terminal. Quitting ends local shells. Splits, multiple windows, notifications, a browser, scrollback search, layout restoration, a settings window, and automatic updates are outside v1.
