# Full Disk Access Prompt — Design Spec

**Date:** 2026-03-29

## Problem

Deckard doesn't appear in macOS System Settings > Privacy & Security > Full Disk Access. Without FDA, commands run inside Deckard's terminal sessions can't access files in protected locations (same limitation that affects Terminal.app and iTerm2 without FDA).

## Solution

Probe known FDA-protected paths at launch to (a) register Deckard in the FDA list and (b) detect whether FDA is already granted. If not granted and the user hasn't opted out, show a one-time-per-launch alert guiding them to enable it.

## Design

### FDA Detection — `FullDiskAccessChecker`

New file: `Sources/App/FullDiskAccessChecker.swift`

An enum with two static methods:

- `hasFullDiskAccess() -> Bool` — Attempts to read multiple known FDA-protected paths:
  - `~/Library/Safari/Bookmarks.plist`
  - `~/Library/Safari/CloudTabs.db`
  - `~/Library/Mail`

  Returns `true` if any path is readable. The act of probing these paths is what causes macOS to register Deckard in the FDA list in System Settings. Multiple paths are tried because some may not exist if the user hasn't used Safari or Mail.

- `openSettings()` — Opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` via `NSWorkspace`.

### Launch Prompt — in `AppDelegate.applicationDidFinishLaunching`

After the main window is shown, on a short delay (`DispatchQueue.main.asyncAfter(deadline: .now() + 1.0)`):

1. Call `FullDiskAccessChecker.hasFullDiskAccess()` — if true, skip (already granted). This probe always runs, even when the prompt is suppressed, because the probe itself is what registers Deckard in the FDA list.
2. Check `UserDefaults.standard.bool(forKey: "suppressFullDiskAccessPrompt")` — if true, skip showing the alert.
3. Show an `NSAlert`:
   - **Style:** Informational
   - **Title:** "Full Disk Access"
   - **Message:** "Deckard is a terminal emulator. Like Terminal and iTerm2, it needs Full Disk Access so that commands running inside it can access all of your files.\n\nYou can grant this in System Settings > Privacy & Security > Full Disk Access."
   - **Buttons (in order):**
     1. "Open System Settings" — calls `FullDiskAccessChecker.openSettings()`
     2. "Not Now" — dismisses, will prompt again next launch
     3. "Don't Ask Again" — sets `suppressFullDiskAccessPrompt = true` in UserDefaults

### UserDefaults Key

- `suppressFullDiskAccessPrompt` (Bool, default false) — when true, the FDA prompt is permanently suppressed.

## Files Changed

1. **New:** `Sources/App/FullDiskAccessChecker.swift` — FDA detection and settings opener
2. **Modified:** `AppDelegate.swift` — call FDA check after window is shown
3. **Modified:** `Deckard.xcodeproj/project.pbxproj` — add new file to build target
