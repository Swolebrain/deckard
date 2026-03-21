# Render Heartbeat & Frozen Surface Detection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect frozen ghostty surfaces (renderer stopped updating despite keyboard input) and fix the stuck-detection gap for surfaces that never received successful character input.

**Architecture:** Track per-surface render timestamps from ghostty's `GHOSTTY_ACTION_RENDER` callback. Enhance `keyDown` stuck detection with three conditions: the existing "char key timeout", a new "never-typed" check, and a new "render stale" check. On detection, attempt a soft nudge (resize) and log diagnostics. Also handle `GHOSTTY_ACTION_RENDERER_HEALTH` for explicit GPU errors.

**Tech Stack:** Swift, GhosttyKit C API, AppKit

---

### Task 1: Add render heartbeat property and routing

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:44` (add property after `lastSuccessfulCharKeyTime`)
- Modify: `Sources/Ghostty/DeckardGhosttyApp.swift:415-428` (handle RENDER and RENDERER_HEALTH)

- [ ] **Step 1: Add `lastRenderActionTime` property to TerminalNSView**

In `Sources/Ghostty/SurfaceView.swift`, after line 44 (`lastSuccessfulCharKeyTime`), add:

```swift
/// Last time a GHOSTTY_ACTION_RENDER was received for this surface.
/// Updated from the action callback thread; read from main thread (benign race).
var lastRenderActionTime: TimeInterval = 0
/// Whether the renderer has reported unhealthy status.
var rendererUnhealthy: Bool = false
```

- [ ] **Step 2: Route RENDER action to the surface view**

In `Sources/Ghostty/DeckardGhosttyApp.swift`, replace the ignored `GHOSTTY_ACTION_RENDERER_HEALTH` / `GHOSTTY_ACTION_RENDER` case (lines 415-428) by splitting them out. The remaining ignored actions stay grouped. Add a helper to resolve the view from the surface target.

Add this helper method to `DeckardGhosttyApp` (before `handleAction`):

```swift
/// Resolve the TerminalNSView for a surface-targeted action.
private func surfaceView(from target: ghostty_target_s) -> TerminalNSView? {
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let ud = ghostty_surface_userdata(surface) else { return nil }
    return Unmanaged<SurfaceCallbackContext>.fromOpaque(ud).takeUnretainedValue().view
}
```

Then in `handleAction`, replace the combined case with:

```swift
case GHOSTTY_ACTION_RENDER:
    // Update render heartbeat — benign race (written here, read on main thread).
    if let view = surfaceView(from: target) {
        view.lastRenderActionTime = ProcessInfo.processInfo.systemUptime
    }
    return true

case GHOSTTY_ACTION_RENDERER_HEALTH:
    if let view = surfaceView(from: target) {
        let health = action.action.renderer_health
        let unhealthy = (health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY)
        DispatchQueue.main.async {
            view.rendererUnhealthy = unhealthy
            DiagnosticLog.shared.log("health",
                "RENDERER_HEALTH: \(unhealthy ? "UNHEALTHY" : "healthy") surfaceId=\(view.surfaceId)")
        }
    }
    return true

case GHOSTTY_ACTION_CELL_SIZE,
     GHOSTTY_ACTION_COLOR_CHANGE,
     GHOSTTY_ACTION_CONFIG_CHANGE,
     GHOSTTY_ACTION_RELOAD_CONFIG,
     GHOSTTY_ACTION_SHOW_CHILD_EXITED,
     GHOSTTY_ACTION_SCROLLBAR,
     GHOSTTY_ACTION_SIZE_LIMIT,
     GHOSTTY_ACTION_INITIAL_SIZE,
     GHOSTTY_ACTION_KEY_SEQUENCE,
     GHOSTTY_ACTION_COMMAND_FINISHED,
     GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    return true
```

- [ ] **Step 3: Build and verify no compiler errors**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift Sources/Ghostty/DeckardGhosttyApp.swift
git commit -m "feat: route RENDER and RENDERER_HEALTH actions to surface views

Track per-surface render heartbeat timestamps from ghostty's
GHOSTTY_ACTION_RENDER callback. Handle GHOSTTY_ACTION_RENDERER_HEALTH
with logging instead of silently ignoring it."
```

---

### Task 2: Fix stuck detection and add render-stale detection

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:423-429` (enhance stuck detection in `keyDown`)

- [ ] **Step 1: Replace the stuck detection block**

In `Sources/Ghostty/SurfaceView.swift`, replace lines 423-429 (the existing stuck detection) with:

```swift
// Stuck detection: keyDown is being called but input isn't working.
// Three conditions (any one triggers):
//   1. Character keys succeeded before but stopped (original check)
//   2. Surface never had a successful character key despite many keyDown calls
//   3. Render heartbeat is stale despite active input
let renderStale = lastRenderActionTime > 0 && (now - lastRenderActionTime) > 3.0
let neverTyped = lastSuccessfulCharKeyTime == 0 && (now - focusGainedTime) > 3.0
let charTimeout = lastSuccessfulCharKeyTime > 0 && (now - lastSuccessfulCharKeyTime) > 2.0

if keyDownCount > 10 && (charTimeout || neverTyped || renderStale || rendererUnhealthy) {
    let reason: String
    if rendererUnhealthy { reason = "renderer_unhealthy" }
    else if renderStale { reason = "render_stale(\(String(format: "%.1f", now - lastRenderActionTime))s)" }
    else if neverTyped { reason = "never_typed" }
    else { reason = "char_timeout(\(String(format: "%.1f", now - lastSuccessfulCharKeyTime))s)" }

    DiagnosticLog.shared.log("input",
        "STUCK(\(reason)): keyDownCount=\(keyDownCount) surface=\(surface != nil) " +
        "lastRender=\(String(format: "%.1f", lastRenderActionTime > 0 ? now - lastRenderActionTime : -1))s " +
        "windowFR=\(type(of: window?.firstResponder)) surfaceId=\(surfaceId)")
}
```

- [ ] **Step 2: Build and verify**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "fix: detect stuck input on surfaces that never had successful keys

Previous stuck detection required lastSuccessfulCharKeyTime > 0, so
surfaces that never processed a character key (e.g. frozen after
session restore) could never trigger it. Add three detection modes:
char_timeout (original), never_typed, and render_stale (no RENDER
actions despite active keyboard input)."
```

---

### Task 3: Add soft recovery nudge on stuck detection

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift` (add nudge after stuck detection, add throttle property)

- [ ] **Step 1: Add a throttle property for recovery attempts**

In `Sources/Ghostty/SurfaceView.swift`, after the `lastRenderActionTime` / `rendererUnhealthy` properties added in Task 1, add:

```swift
/// Last time a recovery nudge was attempted, to avoid spamming.
private var lastRecoveryNudgeTime: TimeInterval = 0
```

- [ ] **Step 2: Add recovery nudge after stuck detection**

Immediately after the `DiagnosticLog.shared.log("input", "STUCK(...)")` block from Task 2, add:

```swift
    // Attempt soft recovery: force a resize to kick the Metal pipeline.
    // Throttle to once per 5 seconds to avoid spamming.
    if (now - lastRecoveryNudgeTime) > 5.0 {
        lastRecoveryNudgeTime = now
        DiagnosticLog.shared.log("input", "STUCK: attempting recovery nudge surfaceId=\(surfaceId)")
        updateSurfaceSize()
        if let s = surface, let window = self.window {
            let scale = window.backingScaleFactor
            surfaceQueue.async {
                ghostty_surface_set_content_scale(s, scale, scale)
            }
        }
    }
```

- [ ] **Step 3: Build and verify**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "fix: attempt soft recovery when stuck input is detected

When stuck detection fires, force a surface resize and content scale
update to kick the Metal rendering pipeline. Throttled to once per 5s
to avoid spamming ghostty with redundant calls."
```

---

### Task 4: Manual verification

- [ ] **Step 1: Launch the app and verify render heartbeat logging**

Build and launch Deckard. Open a terminal tab and type some text. Check the diagnostic log for any new STUCK or RENDERER_HEALTH entries:

```bash
tail -50 ~/Library/Application\ Support/Deckard/diagnostic.log
```

Expected: Normal operation produces no STUCK logs. Render heartbeat updates silently (not logged per-frame).

- [ ] **Step 2: Verify stuck detection fires on a frozen tab (if reproducible)**

If you can reproduce the frozen tab scenario (e.g. after sleep/wake with many restored tabs), check that the diagnostic log shows `STUCK(never_typed)` or `STUCK(render_stale)` entries.
