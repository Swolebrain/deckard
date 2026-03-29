# Full Disk Access Prompt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Deckard appear in macOS Full Disk Access list and prompt users to enable it.

**Architecture:** A small `FullDiskAccessChecker` enum probes FDA-protected paths at launch, registering Deckard in System Settings. If FDA isn't granted and the user hasn't opted out, an `NSAlert` guides them to enable it.

**Tech Stack:** Swift, AppKit (NSAlert, NSWorkspace), UserDefaults

**Spec:** `docs/superpowers/specs/2026-03-29-full-disk-access-prompt-design.md`

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Sources/App/FullDiskAccessChecker.swift` | FDA detection + open System Settings |
| Create | `Tests/FullDiskAccessCheckerTests.swift` | Unit tests for the checker |
| Modify | `Sources/App/AppDelegate.swift` | Call FDA check after window shown |
| Modify | `Deckard.xcodeproj/project.pbxproj` | Add new files to build targets |

---

### Task 1: Create `FullDiskAccessChecker` with tests

**Files:**
- Create: `Sources/App/FullDiskAccessChecker.swift`
- Create: `Tests/FullDiskAccessCheckerTests.swift`

- [ ] **Step 1: Write the test file**

Create `Tests/FullDiskAccessCheckerTests.swift`:

```swift
import XCTest
@testable import Deckard

final class FullDiskAccessCheckerTests: XCTestCase {
    func testHasFullDiskAccessReturnsBool() {
        // Smoke test — the function runs without crashing and returns a Bool.
        // The actual result depends on the test host's FDA status.
        let result = FullDiskAccessChecker.hasFullDiskAccess()
        XCTAssertNotNil(result as Bool)
    }

    func testOpenSettingsURLIsValid() {
        // Verify the URL string parses correctly.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        XCTAssertNotNil(url)
    }
}
```

- [ ] **Step 2: Write the implementation**

Create `Sources/App/FullDiskAccessChecker.swift`:

```swift
import AppKit

enum FullDiskAccessChecker {
    /// Probes known FDA-protected paths.  Returns `true` when any path is
    /// readable (i.e. FDA has been granted).  The probe itself causes macOS
    /// to register Deckard in System Settings > Full Disk Access.
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedPaths = [
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Safari/CloudTabs.db",
            home + "/Library/Mail",
        ]
        return protectedPaths.contains {
            FileManager.default.isReadableFile(atPath: $0)
        }
    }

    /// Opens System Settings directly to the Full Disk Access pane.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 3: Add both files to the Xcode project**

Modify `Deckard.xcodeproj/project.pbxproj` — add four entries:

1. **PBXBuildFile** — `FullDiskAccessChecker.swift` in Deckard target Sources:
```
FDAC0001FDAC0001FDAC0001 /* FullDiskAccessChecker.swift in Sources */ = {isa = PBXBuildFile; fileRef = FDAC0002FDAC0002FDAC0002 /* FullDiskAccessChecker.swift */; };
```

2. **PBXBuildFile** — `FullDiskAccessCheckerTests.swift` in DeckardTests target Sources:
```
FDAC0003FDAC0003FDAC0003 /* FullDiskAccessCheckerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FDAC0004FDAC0004FDAC0004 /* FullDiskAccessCheckerTests.swift */; };
```

3. **PBXFileReference** — both files:
```
FDAC0002FDAC0002FDAC0002 /* FullDiskAccessChecker.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FullDiskAccessChecker.swift; sourceTree = "<group>"; };
FDAC0004FDAC0004FDAC0004 /* FullDiskAccessCheckerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FullDiskAccessCheckerTests.swift; sourceTree = "<group>"; };
```

4. **PBXGroup** — add `FDAC0002FDAC0002FDAC0002` to the App group (after `AABB0007AABB0007AABB0007 /* DeckardHooksInstaller.swift */`):
```
FDAC0002FDAC0002FDAC0002 /* FullDiskAccessChecker.swift */,
```

5. **PBXGroup** — add `FDAC0004FDAC0004FDAC0004` to the Tests group.

6. **PBXSourcesBuildPhase** — add `FDAC0001FDAC0001FDAC0001` to the Deckard target's Sources phase and `FDAC0003FDAC0003FDAC0003` to the DeckardTests target's Sources phase.

- [ ] **Step 4: Build and run tests**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug test -destination 'platform=macOS'
```

Expected: Build succeeds. `FullDiskAccessCheckerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/FullDiskAccessChecker.swift Tests/FullDiskAccessCheckerTests.swift Deckard.xcodeproj/project.pbxproj
git commit -m "feat: add FullDiskAccessChecker to probe FDA-protected paths"
```

---

### Task 2: Add FDA prompt to AppDelegate

**Files:**
- Modify: `Sources/App/AppDelegate.swift:83` (after `windowController?.showWindow(nil)`)

- [ ] **Step 1: Add the FDA check call to AppDelegate**

In `Sources/App/AppDelegate.swift`, after line 83 (`log.log("startup", "=== Startup complete ===")`), add:

```swift
        // Check Full Disk Access and prompt if needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard !FullDiskAccessChecker.hasFullDiskAccess() else { return }
            guard !UserDefaults.standard.bool(forKey: "suppressFullDiskAccessPrompt") else { return }

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Full Disk Access"
            alert.informativeText = "Deckard is a terminal emulator. Like Terminal and iTerm2, it needs Full Disk Access so that commands running inside it can access all of your files.\n\nYou can grant this in System Settings > Privacy & Security > Full Disk Access."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Not Now")
            alert.addButton(withTitle: "Don't Ask Again")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                FullDiskAccessChecker.openSettings()
            case .alertThirdButtonReturn:
                UserDefaults.standard.set(true, forKey: "suppressFullDiskAccessPrompt")
            default:
                break
            }
        }
```

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build
```

Expected: Build succeeds with no errors or warnings.

- [ ] **Step 3: Run tests**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug test -destination 'platform=macOS'
```

Expected: All tests pass (the alert code only runs in `applicationDidFinishLaunching`, which is skipped during tests via the `isRunningTests` guard).

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "feat: prompt user to enable Full Disk Access on launch"
```
