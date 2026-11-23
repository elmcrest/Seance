# Seance

Seance is a single-window macOS terminal with a searchable tab sidebar and a picker for resuming local Claude Code conversations. AppKit hosts the terminal, SwiftUI draws the sidebar, and full libghostty owns each shell and PTY.

Seance is MIT licensed. No telemetry, accounts, or upsells.

## Build and run

Use macOS 14 or later, Xcode with Swift 6, and the Xcode Metal compiler. If Metal is missing, install it with `xcodebuild -downloadComponent MetalToolchain`. The first app build downloads the pinned Ghostty source and a checksummed Zig 0.14.1 toolchain when needed. On Apple Silicon with a recent Xcode, Zig may require an older macOS SDK. The build detects locally installed 15.4 and 14.4 SDKs, or you can supply a compatible path via `SEANCE_MACOS_SDK`.

Run the following commands from the checkout.

```sh
swift test
./scripts/build-app
open -n .build/Seance.app
```

The development bundle and build products live under this worktree’s .build directory. The terminal uses [Ghostty v1.2.3](https://github.com/ghostty-org/ghostty/releases/tag/v1.2.3) at commit `6d2dd585a5d87fa745d48188dd096ca6e63014d0`. It reads Ghostty’s configuration for fonts, themes, and keybindings.

## Tabs and sessions

Press **⌘T** and Return to open a terminal in the current tab’s last reported directory. Type to search saved Claude sessions, then choose one to run `claude --resume` in its directory. Discovery reads local Claude metadata, including projects under `CLAUDE_CONFIG_DIR` when set. It skips missing directories and malformed records. Conversation previews use bounded reads from the beginning and end of transcripts.

Filter the sidebar by title or directory, drag to reorder, and double-click a tab to rename it. Manual and MCP renames share a sticky title override. Clear the name to follow the program title again. While an override is active, the program title can still appear below it.

Quitting closes the local shells and ends their processes. A resumed conversation starts in a fresh terminal. The picker omits sessions attached to open Seance tabs. It recognizes picker launches immediately and uses Claude’s lifecycle hooks for sessions started by typing `claude`. A missed hook can leave the picker’s view of manually started sessions out of date.

## Connect an agent

Run either setup command **inside a Seance tab**, after placing the app where you intend to keep it.

```sh
"$SEANCE_HELPER" setup claude
"$SEANCE_HELPER" setup codex
```

Claude setup adds a user-scoped MCP registration and merges SessionStart and SessionEnd command hooks into Claude’s settings. Codex setup registers the same tools and forwards the current tab environment at client startup. Start a new client session after setup.

| MCP tool | Behavior |
|---|---|
| `list_tabs` | Return tabs in sidebar order, including IDs, titles, directories, and selected state. |
| `get_current_tab` | Return the tab that launched this client, even when another tab has focus. |
| `rename_tab` | Set the caller’s title override, or supply an explicit `tab_id`. Pass `null` as the title to clear it. |

The bundled helper bridges stdio to a private Unix socket in the running app. Each surface receives its own `TAB_ID` and its app’s socket path. Codex can use the MCP tools today. The session picker currently supports Claude Code.

## Parallel development

Use the main checkout for integration. The sibling worktrees are `../seance-terminal` for Ghostty and app composition, `../seance-sidebar` for tab UI, `../seance-mcp` for tools and transport, and `../seance-sessions` for session discovery and the picker. Coordinate manifest changes on main. Each running app gets its own socket by default. An explicit `SEANCE_LISTEN_SOCKET_PATH` for a test run must live inside a private directory owned by the current user.

The integration check uses two real tabs. Focus B, emit a program title change from A, then call `rename_tab` from A. Only A should change. Clear the override to recover the latest program title. Closing A should cause late requests using its ID to fail.

Splits, multiple windows, notifications, a browser, scrollback search, layout restoration, a settings window, and automatic updates are outside v1.
