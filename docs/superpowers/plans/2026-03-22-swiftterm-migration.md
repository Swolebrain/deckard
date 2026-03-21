# SwiftTerm Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace libghostty with SwiftTerm as Deckard's terminal engine, eliminating all surface lifecycle bugs.

**Architecture:** Create a `TerminalSurface` wrapper around SwiftTerm's `LocalProcessTerminalView`, delete all Ghostty integration code, and update `DeckardWindowController` to use the new wrapper. The migration is a clean swap — no incremental coexistence.

**Tech Stack:** Swift, AppKit, SwiftTerm (SPM), `LocalProcessTerminalView`

**Spec:** `docs/superpowers/specs/2026-03-22-swiftterm-migration-design.md`

---

### Task 1: Add SwiftTerm SPM dependency

**Files:**
- Create: `Package.swift` (if using SPM) OR modify `Deckard.xcodeproj` via Xcode SPM integration
- Modify: `Deckard.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add SwiftTerm package via Xcode**

Run in Xcode or via command line:
```bash
# If using xcodebuild with SPM resolution:
# Add to Deckard.xcodeproj via Xcode: File > Add Package Dependencies
# URL: https://github.com/migueldeicaza/SwiftTerm
# Version: 1.12.0 - Next Major
# Add to target: Deckard
```

Alternatively, if the project already uses SPM, add to `Package.swift`:
```swift
.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.12.0")
```

- [ ] **Step 2: Verify the dependency resolves**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug -resolvePackageDependencies 2>&1 | tail -10
```

- [ ] **Step 3: Create a minimal test file to confirm SwiftTerm imports**

Create `Sources/Terminal/TerminalSurface.swift` with a stub:
```swift
import AppKit
import SwiftTerm

/// Wraps a SwiftTerm LocalProcessTerminalView for use in Deckard's tab system.
/// This is the ONLY file that imports SwiftTerm — the rest of Deckard talks
/// to TerminalSurface through its public interface.
class TerminalSurface: NSObject {
    let surfaceId: UUID
    var tabId: UUID?
    var title: String = ""
    var pwd: String?
    var isAlive: Bool { !processExited }
    var onProcessExit: ((TerminalSurface) -> Void)?

    private let terminalView: LocalProcessTerminalView
    private var processExited = false

    /// The NSView to add to the view hierarchy.
    var view: NSView { terminalView }

    init(surfaceId: UUID = UUID()) {
        self.surfaceId = surfaceId
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
    }
}
```

- [ ] **Step 4: Build to verify SwiftTerm links**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/Terminal/TerminalSurface.swift Deckard.xcodeproj
git commit -m "chore: add SwiftTerm SPM dependency and TerminalSurface stub"
```

---

### Task 2: Implement TerminalSurface — shell spawning and delegate callbacks

**Files:**
- Modify: `Sources/Terminal/TerminalSurface.swift`

- [ ] **Step 1: Implement shell spawning and delegate**

Replace the stub with the full implementation:

```swift
import AppKit
import SwiftTerm

/// Wraps a SwiftTerm LocalProcessTerminalView for use in Deckard's tab system.
/// This is the ONLY file that imports SwiftTerm — the rest of Deckard talks
/// to TerminalSurface through its public interface.
class TerminalSurface: NSObject, LocalProcessTerminalViewDelegate {
    let surfaceId: UUID
    var tabId: UUID?
    var title: String = ""
    var pwd: String?
    var isAlive: Bool { !processExited }
    var onProcessExit: ((TerminalSurface) -> Void)?

    private let terminalView: LocalProcessTerminalView
    private var processExited = false
    private var initialInput: String?

    /// The NSView to add to the view hierarchy.
    var view: NSView { terminalView }

    init(surfaceId: UUID = UUID()) {
        self.surfaceId = surfaceId
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
    }

    /// Start a shell process in the terminal.
    func startShell(workingDirectory: String? = nil, command: String? = nil,
                    envVars: [String: String] = [:], initialInput: String? = nil) {
        self.initialInput = initialInput

        let shell = command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Build environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["DECKARD_SURFACE_ID"] = surfaceId.uuidString
        if let tabId { env["DECKARD_TAB_ID"] = tabId.uuidString }
        env["DECKARD_SOCKET_PATH"] = ControlSocket.shared.path
        for (k, v) in envVars { env[k] = v }

        let envPairs = env.map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: envPairs,
            execName: "-" + (shell as NSString).lastPathComponent, // login shell
            initialDirectory: workingDirectory
        )

        DiagnosticLog.shared.log("surface", "startShell: surfaceId=\(surfaceId) shell=\(shell) cwd=\(workingDirectory ?? "(nil)")")
    }

    /// Send text to the terminal (for initial input, paste, etc.)
    func sendInput(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Terminate the shell process.
    func terminate() {
        terminalView.process?.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Size changes are handled internally by SwiftTerm
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
        NotificationCenter.default.post(
            name: .deckardSurfaceTitleChanged,
            object: nil,
            userInfo: ["surfaceId": surfaceId, "title": title]
        )
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        self.pwd = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processExited = true
        DiagnosticLog.shared.log("surface", "processTerminated: surfaceId=\(surfaceId) exitCode=\(exitCode ?? -1)")
        onProcessExit?(self)
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let deckardSurfaceTitleChanged = Notification.Name("deckardSurfaceTitleChanged")
    static let deckardSurfaceClosed = Notification.Name("deckardSurfaceClosed")
    static let deckardNewTab = Notification.Name("deckardNewTab")
    static let deckardCloseTab = Notification.Name("deckardCloseTab")
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```

Note: This will produce errors from other files still importing GhosttyKit — that's expected. The TerminalSurface itself should compile. If not, fix delegate method signatures to match SwiftTerm's actual API.

- [ ] **Step 3: Commit**

```bash
git add Sources/Terminal/TerminalSurface.swift
git commit -m "feat: implement TerminalSurface wrapper around SwiftTerm"
```

---

### Task 3: Strip Ghostty from main.swift and AppDelegate

**Files:**
- Modify: `Sources/App/main.swift`
- Modify: `Sources/App/AppDelegate.swift`

- [ ] **Step 1: Rewrite main.swift**

Replace the entire file — remove `import GhosttyKit`, `ghostty_init()`, and the guard:

```swift
import AppKit

// Install crash handlers as early as possible.
CrashReporter.install()
DiagnosticLog.shared.log("startup", "=== Deckard launch ===")
DiagnosticLog.shared.log("startup", "PID: \(ProcessInfo.processInfo.processIdentifier)")

// Surface any crash report left by a previous run.
CrashReporter.logPreviousCrashIfAny()

// Launch the macOS application.
DiagnosticLog.shared.log("startup", "Creating NSApplication...")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
DiagnosticLog.shared.log("startup", "Entering app.run()")
app.run()
```

- [ ] **Step 2: Rewrite AppDelegate**

Remove: `import GhosttyKit`, `ghosttyApp` property, GHOSTTY_RESOURCES_DIR setup, DeckardGhosttyApp creation, ThemeManager initialization, ghostty notification observers.

Key changes:
- Remove `ghosttyApp` property entirely
- `DeckardWindowController` init no longer takes `ghosttyApp` parameter
- `handleTitleChanged` receives `surfaceId: UUID` instead of `ghostty_surface_t`
- Keep control socket, hooks, menu, Deckard skill installation unchanged
- Keep `handleSurfaceClosed`, `handleNewTab`, `handleCloseTab` but simplify

The `applicationDidFinishLaunching` becomes:
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    let log = DiagnosticLog.shared
    log.log("startup", "applicationDidFinishLaunching entered")
    Self.shared = self

    // Set up the main menu.
    log.log("startup", "Setting up main menu...")
    setupMainMenu()

    // Listen for notifications.
    log.log("startup", "Registering notification observers...")
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(handleSurfaceClosed(_:)), name: .deckardSurfaceClosed, object: nil)
    nc.addObserver(self, selector: #selector(handleTitleChanged(_:)), name: .deckardSurfaceTitleChanged, object: nil)
    nc.addObserver(self, selector: #selector(handleNewTab), name: .deckardNewTab, object: nil)
    nc.addObserver(self, selector: #selector(handleCloseTab), name: .deckardCloseTab, object: nil)

    // Start the control socket for hook communication.
    log.log("startup", "Starting control socket...")
    ControlSocket.shared.start()
    ControlSocket.shared.onMessage = { [weak self] message, reply in
        self?.hookHandler.handle(message, reply: reply)
    }
    setenv("DECKARD_SOCKET_PATH", ControlSocket.shared.path, 1)
    log.log("startup", "Control socket at: \(ControlSocket.shared.path ?? "(nil)")")

    // Install the /deckard feedback skill if gh CLI is available.
    log.log("startup", "Installing Deckard skill...")
    installDeckardSkill()

    // Install Claude Code hooks so Deckard receives session events.
    log.log("startup", "Installing Claude Code hooks...")
    DeckardHooksInstaller.installIfNeeded()

    // Create and show the main window.
    log.log("startup", "Creating window controller...")
    windowController = DeckardWindowController()
    hookHandler.windowController = windowController
    log.log("startup", "Showing main window...")
    windowController?.showWindow(nil)
    log.log("startup", "=== Startup complete ===")
}
```

Update `handleTitleChanged` to use surfaceId instead of ghostty_surface_t:
```swift
@objc private func handleTitleChanged(_ notification: Notification) {
    guard let surfaceId = notification.userInfo?["surfaceId"] as? UUID,
          let title = notification.userInfo?["title"] as? String else { return }
    windowController?.setTitle(title, forSurfaceId: surfaceId)
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/App/main.swift Sources/App/AppDelegate.swift
git commit -m "refactor: remove Ghostty from main.swift and AppDelegate"
```

---

### Task 4: Update DeckardWindowController — replace TerminalNSView with TerminalSurface

This is the largest task. The window controller has ~2000 lines with many Ghostty references.

**Files:**
- Modify: `Sources/Window/DeckardWindowController.swift`

- [ ] **Step 1: Update TabItem to use TerminalSurface**

Change the `surfaceView` property from `TerminalNSView` to `TerminalSurface`:
```swift
class TabItem {
    let id: UUID
    var surface: TerminalSurface  // was: surfaceView: TerminalNSView
    // ... rest unchanged
}
```

Update the initializer accordingly.

- [ ] **Step 2: Remove ghosttyApp property and update init**

Remove:
```swift
private let ghosttyApp: DeckardGhosttyApp
```

Change init from `init(ghosttyApp: DeckardGhosttyApp)` to `init()`.

Remove `currentThemeColors` property. Replace all `currentThemeColors.xxx` and `ThemeManager.shared.currentColors.xxx` references with hardcoded defaults from `ThemeColors.default` or a static `ThemeColors` instance.

- [ ] **Step 3: Rewrite createTabInProject to use TerminalSurface**

Replace the current `createTabInProject` method. The new version:
```swift
private func createTabInProject(_ project: ProjectItem, isClaude: Bool, name: String? = nil, sessionIdToResume: String? = nil) {
    let surface = TerminalSurface()
    let tabName: String
    if let name = name {
        tabName = name
    } else {
        let count = project.tabs.filter { $0.isClaude == isClaude }.count + 1
        let base = isClaude ? "Claude" : "Terminal"
        tabName = "\(base) #\(count)"
    }
    let tab = TabItem(surface: surface, name: tabName, isClaude: isClaude)
    tab.badgeState = isClaude ? .idle : .terminalIdle
    surface.tabId = tab.id

    var envVars: [String: String] = [:]
    if isClaude {
        tab.sessionId = sessionIdToResume
        envVars["DECKARD_SESSION_TYPE"] = "claude"
    }

    // Build initial input for Claude tabs
    let initialInput: String?
    if isClaude {
        let extraArgs = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        let extraArgsSuffix = extraArgs.isEmpty ? "" : " \(extraArgs)"
        var claudeArgs = extraArgsSuffix
        if let sessionIdToResume {
            let encoded = project.path.replacingOccurrences(of: "/", with: "-")
            let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionIdToResume).jsonl"
            if FileManager.default.fileExists(atPath: jsonlPath) {
                claudeArgs = " --resume \(sessionIdToResume)\(extraArgsSuffix)"
            } else {
                tab.sessionId = nil
            }
        }
        initialInput = "clear && exec claude\(claudeArgs)\n"
    } else {
        initialInput = nil
    }

    // Handle process exit
    surface.onProcessExit = { [weak self, weak tab] _ in
        guard let self, let tab else { return }
        DispatchQueue.main.async {
            self.handleSurfaceClosedById(tab.surface.surfaceId)
        }
    }

    DiagnosticLog.shared.log("surface", "createTab: \(isClaude ? "claude" : "terminal") surfaceId=\(surface.surfaceId)")

    surface.startShell(
        workingDirectory: project.path,
        envVars: envVars,
        initialInput: initialInput
    )

    project.tabs.append(tab)
    tabCreationOrder.append(tab.id)
}
```

- [ ] **Step 4: Update showTab to use surface.view**

Replace all `tab.surfaceView` references with `tab.surface.view` and all `TerminalNSView` type checks with `TerminalSurface`-aware code. The `showTab` method uses `tab.surfaceView` — change to `tab.surface`:

In showTab, the view is `tab.surface.view` instead of `tab.surfaceView`.

- [ ] **Step 5: Remove ghostty-specific methods**

Delete these methods entirely:
- `focusedSurface() -> ghostty_surface_t?`
- `forEachSurface(_ body: (ghostty_surface_t) -> Void)`
- `setTitle(_:forSurface surface: ghostty_surface_t?)`
- `setPwd(_:forSurface surface: ghostty_surface_t?)`
- `applyThemeColors(_:)`
- Theme reload observer handler

Add replacement:
```swift
func setTitle(_ title: String, forSurfaceId surfaceId: UUID) {
    for project in projects {
        for tab in project.tabs where tab.surface.surfaceId == surfaceId {
            tab.surface.title = title
            rebuildTabBar()
            return
        }
    }
}
```

- [ ] **Step 6: Update all TerminalNSView type checks**

Search for `is TerminalNSView`, `as? TerminalNSView`, `as! TerminalNSView` and update. The `showTab` removal logic uses `terminalContainerView.subviews where sub is TerminalNSView` — these become checks against `LocalProcessTerminalView` (via `sub === currentTerminalView`) or are removed since single-active-view means only one terminal view is ever in the container.

- [ ] **Step 7: Replace ThemeManager/ThemeColors references with hardcoded defaults**

Replace every `ThemeManager.shared.currentColors.xxx` and `currentThemeColors.xxx` with a static color scheme. For example, use `ThemeColors.default` and store it as a constant:

```swift
private let colors = ThemeColors.default
```

Then replace all references: `colors.sidebarBackground`, `colors.tabBarBackground`, etc.

- [ ] **Step 8: Build**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -10
```

Fix any remaining compilation errors. There will likely be several — work through them one by one.

- [ ] **Step 9: Commit**

```bash
git add Sources/Window/DeckardWindowController.swift
git commit -m "refactor: replace TerminalNSView with TerminalSurface in window controller"
```

---

### Task 5: Update SettingsWindow — remove theme picker

**Files:**
- Modify: `Sources/Window/SettingsWindow.swift`

- [ ] **Step 1: Remove theme picker from Appearance pane**

Remove the theme table, theme search field, theme-related state variables, and `ThemeManager` references from `makeAppearancePane()`. Keep the badge color grid and any other non-theme UI.

If the entire Appearance pane was just the theme picker, simplify it to a placeholder or remove the pane from the tab list.

Remove `import GhosttyKit` if present.

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Window/SettingsWindow.swift
git commit -m "refactor: remove theme picker from settings"
```

---

### Task 6: Delete Ghostty files and submodule

**Files:**
- Delete: `Sources/Ghostty/SurfaceView.swift`
- Delete: `Sources/Ghostty/DeckardGhosttyApp.swift`
- Delete: `Sources/Ghostty/ThemeManager.swift`
- Delete: `ghostty/` submodule
- Modify: `Deckard.xcodeproj/project.pbxproj` — remove GhosttyKit references

- [ ] **Step 1: Delete Ghostty source files**

```bash
rm Sources/Ghostty/SurfaceView.swift
rm Sources/Ghostty/DeckardGhosttyApp.swift
rm Sources/Ghostty/ThemeManager.swift
```

Keep `Sources/Ghostty/ThemeColors.swift` (used by chrome color system).

- [ ] **Step 2: Remove ghostty submodule**

```bash
git submodule deinit ghostty
git rm ghostty
rm -rf .git/modules/ghostty
```

- [ ] **Step 3: Remove GhosttyKit from Xcode project**

Open `Deckard.xcodeproj/project.pbxproj` and remove:
- Library search paths containing `ghostty`
- Linker flags containing `ghostty` (`-lghostty-fat`)
- Header search paths containing `ghostty`
- Any file references to deleted Ghostty source files

This may be easier to do via Xcode's GUI (remove framework reference, update build settings).

- [ ] **Step 4: Remove GhosttyKit imports from any remaining files**

```bash
grep -r "import GhosttyKit" Sources/
```

Remove any remaining `import GhosttyKit` lines. Also remove any remaining `ghostty_` function references that were missed.

- [ ] **Step 5: Build**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -10
```

Fix any remaining references to deleted types or functions.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: remove libghostty, GhosttyKit, and ghostty submodule"
```

---

### Task 7: Wire up PID registration and initial input

**Files:**
- Modify: `Sources/Terminal/TerminalSurface.swift`
- Modify: `Sources/Detection/ProcessMonitor.swift` (if needed)

- [ ] **Step 1: Register shell PID after process starts**

In `TerminalSurface.startShell()`, after `startProcess()`, register the child PID with the control socket. SwiftTerm's `LocalProcessTerminalView` exposes the child PID via its `process` property:

```swift
// After startProcess():
if let pid = terminalView.process?.shellPid {
    // Register with control socket so ProcessMonitor can match this tab
    ControlSocket.shared.send(["type": "register-pid", "pid": "\(pid)", "surfaceId": surfaceId.uuidString])
}
```

Check SwiftTerm's actual API for getting the child PID — it may be `terminalView.childPid` or accessible through `LocalProcess`.

- [ ] **Step 2: Send initial input after shell is ready**

After `startProcess()`, send the initial input with a short delay to ensure the shell's readline is ready:

```swift
if let initialInput {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.sendInput(initialInput)
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Terminal/TerminalSurface.swift
git commit -m "feat: wire up PID registration and initial input for Claude tabs"
```

---

### Task 8: Final build, cleanup, and smoke test

**Files:**
- Various cleanup across all modified files

- [ ] **Step 1: Full clean build**

```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug clean build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` with no errors.

- [ ] **Step 2: Search for any remaining Ghostty references**

```bash
grep -ri "ghostty" Sources/ --include="*.swift" | grep -v "ThemeColors" | grep -v "// was ghostty"
```

Fix any remaining references.

- [ ] **Step 3: Commit any final cleanup**

```bash
git add -A
git commit -m "chore: final cleanup of ghostty references"
```

- [ ] **Step 4: Ask user to test**

Ask the user to restart Deckard and verify:
- App launches without crash
- New Claude tab opens and shows claude prompt
- New Terminal tab opens and shows shell prompt
- Tab switching works (no blank/stuck terminals)
- Session restore works after quit and relaunch
- Typing works in all tabs
- Clipboard paste works
- Links are clickable
