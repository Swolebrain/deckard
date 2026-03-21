# SwiftTerm Migration: Replace libghostty with SwiftTerm

## Problem

libghostty permanently binds each terminal surface to an NSView and manages its own Metal rendering lifecycle. This creates cascading issues in Deckard's tab-based model: surfaces that aren't in the view hierarchy don't render, and surfaces created during session restore may never initialize their renderer. Multiple workaround attempts (hide/unhide, z-ordering, single-active-view) have failed to resolve this fundamental mismatch.

SwiftTerm is a self-contained terminal emulator library (MIT license) that provides a drop-in NSView with built-in PTY management, VT100/xterm emulation, and rendering. Each view handles its own lifecycle with no external tick cycle, surface binding, or renderer lock coordination.

## What Gets Deleted

### Entire files
- `Sources/Ghostty/SurfaceView.swift` — replaced by SwiftTerm wrapper
- `Sources/Ghostty/DeckardGhosttyApp.swift` — tick cycle, action callbacks, config loading
- `Sources/Ghostty/ThemeManager.swift` — theme support removed
- `ghostty/` submodule — the entire embedded Ghostty fork
- GhosttyKit framework references and linker flags in `Deckard.xcodeproj/project.pbxproj` (library search paths, `-lghostty-fat`, header search paths) — replaced by SPM package reference

### Code removed from surviving files
- `Sources/App/main.swift` — `ghostty_init()` bootstrap, `GhosttyKit` import, `GHOSTTY_SUCCESS` check
- `Sources/App/AppDelegate.swift` — `ghosttyApp` property, `GHOSTTY_RESOURCES_DIR`/terminfo env var setup, ghostty notification observers (`handleTitleChanged`, `handleSurfaceClosed` etc.)
- `Sources/Window/DeckardWindowController.swift` — all `TerminalNSView`/`ghostty_surface_*` references, `SurfaceCallbackContext` routing, `forEachSurface`, `focusedSurface()`, `setTitle(_:forSurface:)`, `setPwd(_:forSurface:)`, `applyThemeColors`, `currentThemeColors`, theme reload, focus health timer's surface-nil checks
- `Sources/Window/SettingsWindow.swift` — theme picker UI in Appearance pane (theme table, search field, theme-related state). Badge color grid survives.

### ThemeColors.swift — kept with hardcoded defaults

`ThemeColors.swift` is NOT deleted. The chrome color system (sidebar, tab bar, empty state, text colors) depends on it. Instead:
- Delete `ThemeManager.swift` (theme loading/switching)
- Keep `ThemeColors.swift` with a single hardcoded dark-mode color scheme
- `DeckardWindowController` continues using `ThemeColors` for chrome styling
- The `NSColor` extension helpers (`luminance`, `adjustedBrightness`) survive (used by badge colors)

## What Gets Added

### SwiftTerm dependency
Added via Swift Package Manager. URL: `https://github.com/migueldeicaza/SwiftTerm`. Version: 1.12.0+.

### New file: `Sources/Terminal/TerminalSurface.swift`

Thin wrapper around SwiftTerm's `LocalProcessTerminalView`. Replaces `SurfaceView.swift`. Responsibilities:

1. **Create and configure** a `LocalProcessTerminalView` with Deckard's defaults (font, colors, scrollback: 10,000 lines)
2. **Implement `LocalProcessTerminalViewDelegate`** to route callbacks:
   - `setTerminalTitle` → update `title` property, post notification
   - `hostCurrentDirectoryUpdate` → update `pwd` property
   - `bell` → play system beep
   - `clipboardCopy` → write to system pasteboard
   - `requestOpenLink` → open URL with NSWorkspace
   - `sizeChanged` → log for diagnostics
   - `processTerminated` → post notification for tab cleanup
3. **Expose interface for DeckardWindowController**:

```
TerminalSurface
  .surfaceId: UUID
  .tabId: UUID
  .title: String
  .pwd: String?
  .isAlive: Bool
  .view: NSView  (the LocalProcessTerminalView)
  .startShell(workingDirectory:, command:, envVars:, initialInput:)
  .sendInput(_ text: String)
  .terminate()
  .onProcessExit: ((TerminalSurface) -> Void)?
```

4. **Spawn shell** with env vars: `DECKARD_SURFACE_ID`, `DECKARD_TAB_ID`, `DECKARD_SOCKET_PATH`
5. **PID registration** — after `startProcess()`, read the child PID from SwiftTerm and register it with `ProcessMonitor` directly from Swift. The `register-pid` helper script is no longer needed.
6. **Initial input for Claude tabs** — `initialInput` parameter sends text to the PTY after the shell starts (e.g., `"clear && exec claude...\n"`). Uses SwiftTerm's `send(txt:)`. A short delay or PTY-ready check may be needed to avoid sending before the shell's readline is ready.

### Clipboard handling

SwiftTerm handles selection, copy, paste, and OSC 52 clipboard natively through its NSView. No custom clipboard callback needed. Clipboard image paste (`saveClipboardImage`) logic moves from `DeckardGhosttyApp` to a utility or into `TerminalSurface`.

### Drag and drop

SwiftTerm may not handle file/text drag-and-drop natively. If needed, `TerminalSurface` implements `NSDraggingDestination` and sends dropped text/file paths via `send(txt:)`.

## What Stays the Same

- **DeckardWindowController.swift** — tab/project management, sidebar, tab bar, session restore. References change from `TerminalNSView` to `TerminalSurface`, but the single-active-view swap logic is preserved.
- **ProcessMonitor.swift** — process activity detection per tab (PID registration changes from shell script to direct Swift call)
- **CrashReporter.swift** — crash reporting
- **DiagnosticLog.swift** — diagnostic logging (build tag, session headers)
- **Control socket** — IPC for Claude sessions
- **Hooks** — Claude Code hooks configuration
- **Session management** — project/tab state persistence and restore
- **Settings window** — minus theme picker; badge colors, about pane, other settings survive

## What Gets Simpler

### Tab switching
Swap `TerminalSurface.view` in/out of the container. SwiftTerm handles its own rendering — no Metal layer initialization issues, no viewDidMoveToWindow workarounds needed.

### Session restore
Create `LocalProcessTerminalView` instances. No tick cycle, no wakeup callback, no ghostty_app_tick. Each terminal is fully self-contained. No fd exhaustion from Metal layers.

### Input handling
SwiftTerm handles keyboard, mouse, IME, scroll, selection, URL detection internally via its NSView subclass. No keyDown override, no ghosttyMods, no keyAction, no flagsChanged side detection — all built in.

### No stuck detection
The entire STUCK/recovery nudge system is removed. SwiftTerm doesn't have renderer-lock or surface-lifecycle issues.

### Notification routing simplified
Title and PWD changes come directly through `TerminalViewDelegate` on the `TerminalSurface` instance — no need to match by surface pointer across a global notification. `DeckardWindowController`'s `setTitle(forSurface:)` and `setPwd(forSurface:)` methods are replaced by the `TerminalSurface` updating its own properties and posting a notification with the tab ID.

## Behavioral Changes

- **TERM env var** changes from `xterm-ghostty` to `xterm-256color`. Users with shell configs referencing `xterm-ghostty` need to update. This is also what standard terminals use.
- **Rendering engine** changes from Metal GPU to SwiftTerm's renderer (CoreText default, Metal optional since v1.12.0). For Claude Code text output, no visible difference.

## Migration Boundaries

### Clean interface between Deckard and SwiftTerm

`TerminalSurface` is the only file that imports SwiftTerm. The rest of Deckard talks to `TerminalSurface` through the interface above.

`DeckardWindowController` never imports SwiftTerm directly. If SwiftTerm is ever replaced again, only `TerminalSurface.swift` changes.

## Out of Scope

- Theme support — deleted, may be re-added later with a Deckard-native format
- Ghostty config file compatibility — clean break
- Shell integration scripts — SwiftTerm sets TERM=xterm-256color; shell integration is handled by Claude Code's own mechanisms
- OSC 133 semantic prompts — SwiftTerm parses but doesn't expose them; Deckard uses hooks for Claude detection anyway
- Terminal content reading (readVisibleContent) — was defined but never called
