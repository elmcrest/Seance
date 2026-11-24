# Seance guide

[Back to Seance](../README.md)

## Tabs and sessions

Press **⌘N** for the session picker. **Ctrl+Tab** cycles through every terminal in the current window, visiting each sidebar session’s horizontal tabs from left to right before moving to the next session. **Ctrl+Shift+Tab** reverses the cycle. Both follow your Ghostty next/previous tab bindings. **⌘T** opens a horizontal terminal tab in the selected session, using the active terminal’s last reported working directory. **⌥⌘N** opens an independent window with a terminal in your home directory. **⌘W** closes the active terminal. Search by title, directory, or provider. Choosing a session runs `claude --resume <id>` or `codex resume <id>` in its recorded directory. When the agent exits, the same tab returns to an interactive shell in that directory. Discovery reads local Claude metadata, including projects under `CLAUDE_CONFIG_DIR` when set. It skips missing directories and malformed records. Codex discovery recognizes plain and compressed rollout files under `CODEX_HOME/sessions` (default `~/.codex/sessions`) and uses its local thread index for titles, working directories, and archive status. Compressed rollouts require an index entry. Conversation previews use bounded reads from the beginning and end of transcripts.

In the session picker, type to filter by title, directory, provider, or session ID. Choose **Search conversation contents** at the end of the list to also search locally stored user and assistant messages. Editing the query or closing the picker cancels the scan.

The sidebar identifies local foreground Claude and Codex processes, including agents started directly in a terminal. The provider artwork comes from [Orca](https://github.com/stablyai/orca/blob/d889dccbc35b3e812ab8378ab442da2450ba30c4/src/renderer/src/components/status-bar/accounts/provider-icons.tsx) under its [MIT license](../Resources/AgentIcons/Orca-LICENSE).

Seance plays the macOS system alert sound for Claude Code permission prompts, AskUserQuestion, and MCP requests for user input. For Codex, Seance recognizes approval, question, and plan prompts in the TUI’s terminal notifications. Delivery follows Codex’s notification and focus settings and Ghostty’s `desktop-notifications` setting.

Use your terminal paste shortcut (normally **⌘V**) to paste a copied screenshot as a local PNG path. Seance removes its temporary screenshots when it quits. Copied Finder files paste as paths to the originals.

Filter the sidebar by title or directory, drag to reorder, and double-click a tab to rename it. Manual and MCP renames share a sticky title override. Clear the name to follow the program title again. While an override is active, the program title can still appear below it.

### Restoring agent sessions (development build)

On a normal quit, Seance saves open Claude Code and Codex conversations with known session IDs. On launch it restores their sidebar order in one window and resumes the selected conversation. Selecting another row starts that agent on demand. If a directory or transcript is unavailable, or the conversation is already in use, the row stays available to retry or close. Agents exited before quitting and shell-only tabs are omitted. Claude’s hooks can identify manually started sessions. Restoration requires a known session ID.

The snapshot contains session IDs, providers, titles, working directories, order, and selection. It lives under `~/Library/Application Support/Seance/Agent Workspaces/`. Development builds use a separate directory. Each conversation starts in a fresh terminal.

The picker omits sessions attached to open Seance tabs. It recognizes picker launches immediately and uses Claude’s lifecycle hooks for sessions started by typing `claude`. A missed hook can leave the picker’s view of manually started sessions out of date.

## Connect an agent

Run either setup command **inside a Seance tab**, after placing the app where you intend to keep it.

```sh
"$SEANCE_HELPER" setup claude
"$SEANCE_HELPER" setup codex
```

Claude setup adds a user-scoped MCP registration and merges session lifecycle and input-request hooks into Claude’s settings. Re-run setup after upgrading to install the new hooks. Codex setup registers the same tools and forwards the current tab environment at client startup. Start a new client session after setup.

| MCP tool | Behavior |
|---|---|
| `list_tabs` | Return terminal tabs across all windows, including IDs, titles, directories, and selected state. |
| `get_current_tab` | Return the tab that launched this client, even when another tab has focus. |
| `rename_tab` | Set the caller’s title override, or supply an explicit `tab_id`. Pass `null` as the title to clear it. |

The bundled helper bridges stdio to a private Unix socket in the running app. Each surface receives its own `TAB_ID` and its app’s socket path.

## Build and run

Use macOS 14 or later, Xcode with Swift 6, and the Xcode Metal compiler. If Metal is missing, install it with `xcodebuild -downloadComponent MetalToolchain`. The first app build downloads the pinned Ghostty source and a checksummed Zig 0.14.1 toolchain when needed. On Apple Silicon with a recent Xcode, Zig may require an older macOS SDK. The build detects locally installed 15.4 and 14.4 SDKs, or you can supply a compatible path via `SEANCE_MACOS_SDK`.

The app icon build uses `resvg` to render the SVG artwork. Install it with `brew install resvg` if needed.

Run the following commands from the checkout.

```sh
swift test
./scripts/build-app
open -n .build/Seance.app
```

The development bundle and build products live under this worktree’s .build directory. The terminal uses [Ghostty v1.2.3](https://github.com/ghostty-org/ghostty/releases/tag/v1.2.3) at commit `6d2dd585a5d87fa745d48188dd096ca6e63014d0`. It reads Ghostty’s configuration for fonts, themes, and keybindings.

## Updates and releases

Choose **Seance → Check for Updates…** to check GitHub for a newer stable download for this Mac. If one is available, **View Release** opens the release notes and ZIP in your browser. Quit Seance when you’re ready and replace the app in Applications. The check runs only when you choose the menu item and uses the public GitHub API without an account.

GitHub Actions builds and tests the Apple Silicon app on pushes and pull requests. Push the release commit and its version tag together with `git push --atomic origin main vX.Y.Z` to build and test once in the tag workflow. Successful builds have a downloadable CI artifact. To build the same optimized bundle locally, run `./scripts/build-app release`. The output is `.build/distribution/Seance.app`.

To publish a stable release, update both version fields in `Sources/Info.plist`, commit the change, and push a tag such as `v0.3.0` matching `CFBundleShortVersionString`. The tag workflow signs the tested bundle with Developer ID, submits it for Apple notarization, staples the ticket, and publishes the ZIP to [GitHub Releases](https://github.com/elmcrest/Seance/releases).

Maintainers configure these secrets in the GitHub Actions **release** environment. Branch and pull-request builds use ad hoc signing.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as a password-protected PKCS#12 file |
| `DEVELOPER_ID_P12_PASSWORD` | Password for that export |
| `NOTARY_KEY_BASE64` | Base64-encoded App Store Connect team API private key (.p8) for notarization |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | Key ID and issuer ID for that team API key |

## Parallel development

Use the main checkout for integration. The sibling worktrees are `../seance-terminal` for Ghostty and app composition, `../seance-sidebar` for tab UI, `../seance-mcp` for tools and transport, and `../seance-sessions` for session discovery and the picker. Coordinate manifest changes on main. Each running app gets its own socket by default. An explicit `SEANCE_LISTEN_SOCKET_PATH` for a test run must live inside a private directory owned by the current user.

The integration check uses two real tabs. Focus B, emit a program title change from A, then call `rename_tab` from A. Only A should change. Clear the override to recover the latest program title. Closing A should cause late requests using its ID to fail.

Splits, desktop notification banners, a browser, scrollback search, full window and shell layout restoration, a settings window, and automatic updates are outside v1.
