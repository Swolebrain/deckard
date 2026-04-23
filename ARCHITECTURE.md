# Deckard — Architecture

Deckard is a macOS terminal emulator purpose-built for running multiple Claude Code sessions in parallel. It wraps [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) terminal views, integrates with tmux for session persistence, and installs Claude Code event hooks to reflect session state in the UI.

---

## Source Layout

```
Sources/
  App/          — startup, lifecycle, entrypoints
  Control/      — Unix domain socket server
  Detection/    — hook routing, process monitoring, context/quota tracking
  Session/      — state persistence, session explorer, AI summaries
  Terminal/     — SwiftTerm wrapper (isolated; only file that imports SwiftTerm)
  Theme/        — color scheme loading and application
  Window/       — all AppKit UI (window, sidebar, tab bar, quota widget, settings)
Resources/
  bin/          — register-pid shell helper
  themes/       — 200+ iTerm2-format color scheme files
```

---

## Core Data Model

```
DeckardWindowController
  └── [ProjectItem]          one per open folder (sidebar rows)
        └── [TabItem]        one per terminal tab (horizontal tab bar)
              └── TerminalSurface   wraps a SwiftTerm LocalProcessTerminalView
```

**`ProjectItem`** (`Window/DeckardWindowController.swift:66`) — an open folder. Owns a list of tabs and tracks which tab is selected.

**`TabItem`** (`Window/DeckardWindowController.swift:16`) — a Claude or plain terminal tab. Holds:
- `surface: TerminalSurface` — the actual terminal view
- `sessionId: String?` — Claude Code session UUID (set after `hook.session-start`)
- `badgeState: BadgeState` — drives the colored status dot in the UI

**`BadgeState`** values: `none`, `idle`, `thinking`, `waitingForInput`, `needsPermission`, `error`, `terminalIdle`, `terminalActive`, `terminalError`, `completedUnseen`, `terminalCompletedUnseen`.

**`SidebarFolder`** (`Window/DeckardWindowController.swift:83`) — optional grouping of projects in the sidebar.

---

## Startup Sequence (`App/AppDelegate.swift`)

1. Load themes (`ThemeManager`)
2. Start `ControlSocket` (Unix domain socket) and set `DECKARD_SOCKET_PATH` in env
3. Install `/deckard` Claude Code skill (`~/.claude/commands/deckard.md`) if `gh` is present
4. Install Claude Code hooks into `~/.claude/settings.json` (`DeckardHooksInstaller`)
5. Parse `claude --flags` for settings autocomplete (`ClaudeCLIFlags`)
6. Clean up orphaned tmux sessions from prior runs
7. Create `DeckardWindowController` and restore previous session state
8. Probe Full Disk Access; show prompt if missing

---

## IPC: Control Socket (`Control/ControlSocket.swift`)

A Unix domain socket at `$TMPDIR/deckard-<uid>.sock`. Receives newline-delimited JSON messages from:
- Claude Code hook shell scripts (`~/.deckard/hooks/notify.sh`)
- The statusline script (`~/.deckard/hooks/statusline.sh`)
- The `register-pid` helper (`Resources/bin/register-pid`)

All messages are decoded into `ControlMessage` and dispatched to `HookHandler`.

**`ControlMessage` fields**: `command`, `surfaceId`, `sessionId`, `pid`, `notificationType`, `message`, `workingDirectory`, `name`, `tabId`, `key`, `value`, `fiveHourUsed`, `fiveHourResetsAt`, `sevenDayUsed`, `sevenDayResetsAt`.

The socket self-heals: a `DispatchSourceTimer` fires every 30 s to probe the socket and restart it if unresponsive.

---

## Hook Routing (`Detection/HookHandler.swift`)

`HookHandler.handle(_:reply:)` is the central dispatcher. Commands and their effects:

| Command | Effect |
|---|---|
| `hook.session-start` | Sets badge → `waitingForInput`; captures `sessionId` from Claude Code |
| `hook.stop` / `hook.stop-failure` | Sets badge → `completedUnseen` if tab is unfocused, else `waitingForInput` |
| `hook.notification` | Sets badge → `needsPermission` (permission type) or `waitingForInput` |
| `hook.user-prompt-submit` | Sets badge → `thinking` |
| `hook.pre-tool-use` | Sets badge → `thinking` |
| `hook.post-tool-use` | Forwards rate limits only |
| `register-pid` | Hands shell PID to `ProcessMonitor` |
| `list-tabs` / `create-tab` / `rename-tab` / `close-tab` / `focus-tab` | Remote control from scripts |
| `quota-update` | Forwards rate limit data to `QuotaMonitor` |
| `ping` | Health check; replies `pong` |

Any hook message that includes rate limit fields (`fiveHourUsed`, etc.) is forwarded to `QuotaMonitor.update(...)`.

---

## Hooks Installation (`App/DeckardHooksInstaller.swift`)

On every launch, Deckard writes two shell scripts and patches `~/.claude/settings.json`:

- **`~/.deckard/hooks/notify.sh`** — receives Claude Code hook events (`session-start`, `stop`, `pre-tool-use`, `notification`, `user-prompt-submit`). Extracts `session_id` for `session-start`, then sends a JSON message to the control socket via `nc -U`.
- **`~/.deckard/hooks/statusline.sh`** — receives the full `/status` JSON from Claude Code's statusLine mechanism, extracts rate limit fields, and sends a `quota-update` message. Also delegates to the user's original statusLine command (saved at `~/.deckard/original-statusline.json`).

Hook events registered in `~/.claude/settings.json`:
`SessionStart`, `Stop`, `StopFailure` (≥ claude 2.1.78), `PreToolUse`, `Notification`, `UserPromptSubmit`.

The installer is version-aware: it runs `claude --version` and skips hooks that require a newer Claude Code version, preventing settings file rejection.

---

## Terminal Surface (`Terminal/TerminalSurface.swift`)

**The only file that imports SwiftTerm.** Everything else interacts through `TerminalSurface`'s public API.

Key behaviors:
- **tmux wrapping** — terminal tabs (non-Claude) are wrapped in `tmux -L deckard new-session -A -s deckard-<id>`. The `-A` flag attaches to an existing session if the name matches, enabling session persistence across app restarts. Claude tabs do not use tmux (they manage their own resume via `--resume <sessionId>`).
- **Initial input** — Claude tabs have `"clear && exec claude [args]\n"` sent to the shell 0.3 s after startup. Keyboard events are swallowed during this window.
- **File drag-and-drop** — `DeckardTerminalView` (private subclass) accepts file URLs from Finder and pastes shell-escaped paths.
- **Process exit** — on exit, non-Claude tabs with a tmux session trigger a shell restart via `restartShell()`; others remove the tab.
- **Environment** — every shell receives `DECKARD_SURFACE_ID`, `DECKARD_TAB_ID`, `DECKARD_SOCKET_PATH`, and `TERM_PROGRAM=Deckard`.

---

## Process Monitor (`Detection/ProcessMonitor.swift`)

Polls every 1 s (from a timer in `DeckardWindowController`) to detect activity in terminal tabs. Determines whether a foreground process is running by comparing the shell's process group (`e_pgid`) against the terminal's foreground group (`e_tpgid`). Measures CPU time delta and disk I/O via `proc_pidinfo` / `proc_pid_rusage`; falls back to a persistent `/bin/sh` running `ps -o cputime=` for root-owned processes.

Shell PIDs are registered via the `register-pid` control socket command (sent by `Resources/bin/register-pid`). The monitor caches `surfaceId → (login PID, shell PID)` pairs.

Requires 2 consecutive active polls before transitioning a tab to `terminalActive` (filters scheduler noise).

---

## Context & Quota (`Detection/ContextMonitor.swift`, `Detection/QuotaMonitor.swift`)

**`ContextMonitor`** reads Claude Code session JSONL files (`~/.claude/projects/<encoded-path>/<session-id>.jsonl`) by tail-reading the last 256 KB (then 1 MB if needed) to find the most recent `usage` entry. Reports `inputTokens + cacheReadTokens` against per-model context limits. Also provides `listSessions`, `parseTimeline`, `parseActions`, and `truncateSession` for the Session Explorer.

Project paths are encoded using `claudeProjectDirName` (extension on `String`) which replaces every non-alphanumeric-or-dash character with `-`, matching what the Claude Code CLI does.

**`QuotaMonitor`** accumulates rate limit percentages (`fiveHourUsed`, `sevenDayUsed`) forwarded from hook events. Also computes a live tokens-per-minute rate from the most recently modified JSONL. Caches the last snapshot in `UserDefaults` (kept for ≤ 6 h) so the widget shows something immediately on relaunch. Posts `QuotaMonitor.quotaDidChange` notifications; the quota widget (`Window/QuotaView.swift`) observes this.

---

## State Persistence

**Session state** (`Session/SessionState.swift`):
- Saved to `~/Library/Application Support/Deckard/state.json`
- Schema: `DeckardState` → `[ProjectState]` → `[ProjectTabState]` + sidebar folder/order state
- Autosaved every 8 s when dirty; also saved on quit and on project/tab changes
- `SessionManager` handles encode/decode and autosave timer

**Session names** — `~/Library/Application Support/Deckard/session-names.json` maps `sessionId → tab name` so names persist across restarts.

**AI summaries** — `~/Library/Application Support/Deckard/session-summaries.json` caches `claude --print`-generated one-liners for Session Explorer entries.

**UI preferences** — `UserDefaults`: `sidebarWidth`, `sidebarCollapsed`, `terminalFontName`, `terminalFontSize`, `terminalScrollback`, `tmuxOptions`, `claudeExtraArgs`, `useTmux`, `sidebarVibrancy`, `suppressFullDiskAccessPrompt`, `promptForSessionArgs`.

---

## Session Explorer (`Session/SessionExplorer*.swift`, `Session/SummaryManager.swift`)

Opened via File > Explore Sessions. Shows a timeline of past Claude Code sessions for the current project. `ContextMonitor.parseTimeline` and `parseActions` extract user messages and tool uses from JSONL. `SummaryManager` generates one-line AI summaries by calling `claude --print --model haiku --effort low -p <prompt>` as a subprocess; results are cached. The explorer also supports forking a session (writes a truncated copy of the JSONL via `ContextMonitor.truncateSession`, then opens a new tab with `--resume <new-id> --fork-session`).

---

## Theme System (`Theme/ThemeManager.swift`, `Terminal/TerminalColorScheme.swift`)

`ThemeManager` loads iTerm2-format `.itermcolors` / plain property-list files from `Resources/themes/` (200+ themes bundled). `TerminalColorScheme.apply(to:)` pushes the 18 ANSI color slots plus background/foreground into a SwiftTerm `LocalProcessTerminalView`. `ThemeColors` derives non-terminal chrome colors (sidebar, tab bar, text) from the scheme's background luminance.

---

## Window / UI Structure (`Window/`)

| File | Responsibility |
|---|---|
| `DeckardWindowController.swift` | Main window; owns `[ProjectItem]`; manages layout (split view, sidebar, tab bar, terminal container); all project/tab CRUD |
| `SidebarController.swift` | Drag-and-drop reordering logic for sidebar rows and folders |
| `SidebarViews.swift` | `VerticalTabRowView` (sidebar row), `SidebarDropZone` |
| `TabBarController.swift` | Drag-and-drop reordering for horizontal tabs |
| `TabBarViews.swift` | `HorizontalTabView` (individual tab button) |
| `QuotaView.swift` | Context bar and quota sparkline widget at the bottom of the sidebar |
| `SettingsWindow.swift` | Multi-pane settings panel (General, Terminal, Themes, About) |
| `ProjectPicker.swift` | Open Folder sheet (NSOpenPanel wrapper) |
| `ClaudeArgsField.swift` | Autocomplete text field for Claude CLI flags |
| `ThemeCardView.swift` | Theme preview card in Settings > Themes |

The layout is a vertical `NSSplitView`: **sidebar** (left, 210 px default, collapsible) + **right pane** (tab bar 28 px tall + terminal container filling remaining space). Only one `TerminalSurface.view` lives in the terminal container at a time; switching tabs swaps it out.

---

## External Files Modified at Runtime

| Path | Purpose |
|---|---|
| `~/.claude/settings.json` | Hook registration + statusLine override |
| `~/.claude/commands/deckard.md` | `/deckard` slash command for filing issues |
| `~/.deckard/hooks/notify.sh` | Hook handler script (overwritten on each launch) |
| `~/.deckard/hooks/statusline.sh` | StatusLine script (overwritten on each launch) |
| `~/.deckard/original-statusline.json` | Saved copy of user's prior statusLine config |

---

## Dependencies (`project.yml` / Swift Package Manager)

| Package | Use |
|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator core |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Auto-update (EdDSA-signed, feed at `github.com/gi11es/deckard`) |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | User-configurable hotkeys |

No networking code in Deckard itself — all Anthropic API traffic goes through the `claude` CLI subprocess.
