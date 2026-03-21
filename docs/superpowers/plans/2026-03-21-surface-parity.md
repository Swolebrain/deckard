# Surface Handling Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Deckard's Ghostty surface handling in line with upstream Ghostty, eliminating threading races, stuck input, and missing mouse/input features.

**Architecture:** Remove the `surfaceQueue` off-main-thread dispatching and call all `ghostty_surface_*` functions directly on the main thread (matching Ghostty), except `ghostty_surface_free()` which stays on a background queue. Then add missing mouse event handling, input features, and a focus guard for the z-order tab model.

**Tech Stack:** Swift, AppKit, GhosttyKit (libghostty C API)

**Spec:** `docs/superpowers/specs/2026-03-21-surface-parity-design.md`

---

### Task 1: Remove surfaceQueue from keyAction

The biggest change — move `ghostty_surface_key()` back to the main thread and restore the return value.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:688-738` (keyAction method)
- Modify: `Sources/Ghostty/SurfaceView.swift:528-548` (callers: keyDown, keyUp)

- [ ] **Step 1: Rewrite keyAction to be synchronous on main thread**

Replace the current async `keyAction` method (lines 688-738) with a synchronous version that calls `ghostty_surface_key()` directly:

```swift
/// Send a key event to Ghostty. Based on Ghostty's keyAction (MIT).
/// Text is only sent if the first codepoint is printable (>= 0x20).
@discardableResult
private func keyAction(
    _ action: ghostty_input_action_e,
    event: NSEvent,
    translationMods: NSEvent.ModifierFlags? = nil,
    text: String? = nil,
    composing: Bool = false
) -> Bool {
    guard let surface = self.surface else { return false }

    var keyEv = Self.ghosttyKeyEvent(event, action, translationMods: translationMods)
    keyEv.composing = composing

    let start = ProcessInfo.processInfo.systemUptime
    let result: Bool
    if let text, !text.isEmpty,
       let codepoint = text.utf8.first, codepoint >= 0x20 {
        result = text.withCString { ptr in
            keyEv.text = ptr
            return ghostty_surface_key(surface, keyEv)
        }
    } else {
        result = ghostty_surface_key(surface, keyEv)
    }

    let elapsed = ProcessInfo.processInfo.systemUptime - start

    // Track successful character key actions (non-modifier press/repeat).
    let isModifierOnly = [55, 56, 57, 58, 59, 60, 61, 62, 63].contains(Int(event.keyCode))
    if result && !isModifierOnly && (action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT) {
        lastSuccessfulCharKeyTime = start
    }

    // Verbose logging for first 5s after focus gain, or on failure/slowness
    let sinceFocus = start - focusGainedTime
    if elapsed > 0.1 || !result || (sinceFocus < 5 && !isModifierOnly) {
        DiagnosticLog.shared.log("input",
            "keyAction: keyCode=\(event.keyCode) result=\(result) elapsed=\(String(format: "%.3f", elapsed))s surfaceId=\(surfaceId)" +
            (sinceFocus < 5 ? " [VERBOSE sinceFocus=\(String(format: "%.1f", sinceFocus))s]" : ""))
    }
    return result
}
```

- [ ] **Step 2: Restore return value at call sites**

In `keyDown` (lines 528-539), `keyUp` (line 548), and `flagsChanged` (line 573), the calls already don't use the return value, so no change needed — just verify they compile with `@discardableResult`.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "refactor: move ghostty_surface_key back to main thread

Remove surfaceQueue dispatch from keyAction, calling ghostty_surface_key()
synchronously on the main thread to match Ghostty upstream. Restores the
return value and eliminates key event ordering races."
```

---

### Task 2: Remove surfaceQueue from focus, size, scale, preedit, text, and config

Move all remaining `surfaceQueue` and `DispatchQueue.global` dispatches back to the main thread.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:54-56` (remove surfaceQueue property)
- Modify: `Sources/Ghostty/SurfaceView.swift:263-296` (becomeFirstResponder, resignFirstResponder)
- Modify: `Sources/Ghostty/SurfaceView.swift:212-258` (viewDidUnhide, viewDidChangeBackingProperties, updateSurfaceSize)
- Modify: `Sources/Ghostty/SurfaceView.swift:785-803` (syncPreedit)
- Modify: `Sources/Ghostty/SurfaceView.swift:811-835` (performDragOperation)
- Modify: `Sources/Ghostty/SurfaceView.swift:178-202` (destroySurface — keep background free, remove queue drain)
- Modify: `Sources/Ghostty/SurfaceView.swift:454-466` (stuck detection recovery nudge)
- Modify: `Sources/Ghostty/DeckardGhosttyApp.swift:340-348` (reloadConfigWithTheme)

- [ ] **Step 1: Remove surfaceQueue property declaration**

Delete lines 54-56:
```swift
    /// Serial queue for ghostty surface calls that acquire the renderer/IO lock.
    /// Avoids deadlocking the main thread (same pattern as destroySurface/set_focus).
    private let surfaceQueue = DispatchQueue(label: "com.deckard.surface-io", qos: .userInteractive)
```

- [ ] **Step 2: Make becomeFirstResponder and resignFirstResponder synchronous**

In `becomeFirstResponder` (lines 263-279), replace the async dispatch:
```swift
if let s = surface {
    DispatchQueue.global(qos: .userInteractive).async {
        ghostty_surface_set_focus(s, true)
    }
}
```
with:
```swift
surface.map { ghostty_surface_set_focus($0, true) }
```

Same for `resignFirstResponder` (lines 281-296) — replace the async dispatch with:
```swift
surface.map { ghostty_surface_set_focus($0, false) }
```

- [ ] **Step 3: Make viewDidUnhide, viewDidChangeBackingProperties, updateSurfaceSize synchronous**

In `viewDidUnhide` (lines 223-224), replace:
```swift
surfaceQueue.async {
    ghostty_surface_set_content_scale(surface, scale, scale)
}
```
with:
```swift
ghostty_surface_set_content_scale(surface, scale, scale)
```

Same pattern in `viewDidChangeBackingProperties` (lines 246-248).

In `updateSurfaceSize` (lines 256-258), replace:
```swift
surfaceQueue.async {
    ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
}
```
with:
```swift
ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
```

- [ ] **Step 4: Make syncPreedit synchronous**

In `syncPreedit` (lines 785-803), remove the `surfaceQueue.async` wrappers. The method becomes:
```swift
private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface = self.surface else { return }
    if markedText.length > 0 {
        let str = markedText.string
        let len = str.utf8CString.count
        if len > 0 {
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(len - 1))
            }
        }
    } else if clearIfNeeded {
        ghostty_surface_preedit(surface, nil, 0)
    }
}
```

- [ ] **Step 5: Make performDragOperation synchronous**

In `performDragOperation` (lines 811-835), remove the `surfaceQueue.async` wrappers from the two `ghostty_surface_text` calls. Both become direct calls:
```swift
text.withCString { ptr in
    ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
}
```

- [ ] **Step 6: Simplify destroySurface**

In `destroySurface` (lines 178-202), remove the surfaceQueue drain. Since there are no more pending surfaceQueue items, just dispatch free directly:
```swift
if let surface = surface {
    DispatchQueue.global(qos: .utility).async {
        ghostty_surface_free(surface)
        ctx?.release()
    }
} else {
    ctx?.release()
}
```

- [ ] **Step 7: Simplify stuck detection recovery nudge**

In the recovery nudge (lines 460-465), replace the `surfaceQueue.async` call:
```swift
surfaceQueue.async {
    ghostty_surface_set_content_scale(surface, scale, scale)
}
```
with:
```swift
ghostty_surface_set_content_scale(surface, scale, scale)
```

- [ ] **Step 8: Move reloadConfigWithTheme back to main thread**

In `DeckardGhosttyApp.swift` (lines 340-348), replace:
```swift
DispatchQueue.global(qos: .userInitiated).async {
    ghostty_app_update_config(app, newConfig)
    for surface in surfaces {
        ghostty_surface_update_config(surface, newConfig)
    }
    if let oldConfig { ghostty_config_free(oldConfig) }
}
```
with:
```swift
ghostty_app_update_config(app, newConfig)
for surface in surfaces {
    ghostty_surface_update_config(surface, newConfig)
}
if let oldConfig { ghostty_config_free(oldConfig) }
```

- [ ] **Step 9: Remove stale threading comments**

Remove comments that reference surfaceQueue, "benign race", or "dispatch to avoid deadlocking" from all modified locations. The `lastRenderActionTime` comment (line 46) about "benign race" is still valid since it's written from the action callback thread.

- [ ] **Step 10: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 11: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift Sources/Ghostty/DeckardGhosttyApp.swift
git commit -m "refactor: remove surfaceQueue, call ghostty_surface_* on main thread

Move all ghostty_surface_set_focus, set_size, set_content_scale, preedit,
text, and config update calls back to the main thread, matching Ghostty
upstream. Keep ghostty_surface_free on background queue (also matches
upstream). Eliminates threading races between mouse and key events."
```

---

### Task 3: Add focused guard to performKeyEquivalent

Prevent background surfaces from intercepting key equivalents in the z-order model.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:576-578` (performKeyEquivalent)

- [ ] **Step 1: Add first-responder guard**

After the existing `guard event.type == .keyDown` line (577), add:
```swift
guard window?.firstResponder === self else { return false }
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "fix: guard performKeyEquivalent against non-focused surfaces

With z-ordering, all surfaces are in the responder chain. Only the
first-responder surface should process key equivalents."
```

---

### Task 4: Right-click consumption

Check return value and call super if not consumed.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:323-333` (rightMouseDown, rightMouseUp)

- [ ] **Step 1: Update rightMouseDown and rightMouseUp**

Replace `rightMouseDown` (lines 323-327):
```swift
override func rightMouseDown(with event: NSEvent) {
    guard let surface = self.surface else { return super.rightMouseDown(with: event) }
    let mods = Self.ghosttyMods(from: event)
    if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
        super.rightMouseDown(with: event)
    }
}
```

Replace `rightMouseUp` (lines 329-333):
```swift
override func rightMouseUp(with event: NSEvent) {
    guard let surface = self.surface else { return super.rightMouseUp(with: event) }
    let mods = Self.ghosttyMods(from: event)
    if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
        super.rightMouseUp(with: event)
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "fix: pass unconsumed right-click events to super for context menus"
```

---

### Task 5: Mouse button mapping

Support buttons beyond middle-click.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:335-355` (otherMouseDown, otherMouseUp, otherMouseDragged)
- Modify: `Sources/Ghostty/SurfaceView.swift:870-883` (add ghosttyMouseButton helper)

- [ ] **Step 1: Add mouse button mapping function**

Add after `ghosttyMods(fromCocoa:)` (line 883):
```swift
/// Map NSEvent buttonNumber to Ghostty mouse button.
/// Matches Ghostty's MouseButton.init(fromNSEventButtonNumber:).
static func ghosttyMouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e? {
    switch buttonNumber {
    case 0: return GHOSTTY_MOUSE_LEFT
    case 1: return GHOSTTY_MOUSE_RIGHT
    case 2: return GHOSTTY_MOUSE_MIDDLE
    case 3: return GHOSTTY_MOUSE_EIGHT    // Back
    case 4: return GHOSTTY_MOUSE_NINE     // Forward
    case 5: return GHOSTTY_MOUSE_SIX
    case 6: return GHOSTTY_MOUSE_SEVEN
    case 7: return GHOSTTY_MOUSE_FOUR
    case 8: return GHOSTTY_MOUSE_FIVE
    case 9: return GHOSTTY_MOUSE_TEN
    case 10: return GHOSTTY_MOUSE_ELEVEN
    default: return nil
    }
}
```

- [ ] **Step 2: Update otherMouseDown, otherMouseUp, otherMouseDragged**

Replace all three methods:
```swift
override func otherMouseDown(with event: NSEvent) {
    guard let surface = self.surface,
          let button = Self.ghosttyMouseButton(from: event.buttonNumber) else {
        super.otherMouseDown(with: event); return
    }
    let mods = Self.ghosttyMods(from: event)
    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, mods)
}

override func otherMouseUp(with event: NSEvent) {
    guard let surface = self.surface,
          let button = Self.ghosttyMouseButton(from: event.buttonNumber) else {
        super.otherMouseUp(with: event); return
    }
    let mods = Self.ghosttyMods(from: event)
    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, mods)
}

override func otherMouseDragged(with event: NSEvent) {
    guard Self.ghosttyMouseButton(from: event.buttonNumber) != nil else {
        super.otherMouseDragged(with: event); return
    }
    guard let surface = self.surface else { return }
    let pos = convert(event.locationInWindow, from: nil)
    let mods = Self.ghosttyMods(from: event)
    ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "feat: support all mouse buttons, matching Ghostty's button mapping"
```

---

### Task 6: Scroll momentum phase

Include momentum phase in scroll events.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:394-408` (scrollWheel)

- [ ] **Step 1: Update scrollWheel to encode momentum**

Replace the scroll mods encoding (lines 403-407):
```swift
override func scrollWheel(with event: NSEvent) {
    guard let surface = self.surface else { return }
    var x = event.scrollingDeltaX
    var y = event.scrollingDeltaY
    let precision = event.hasPreciseScrollingDeltas
    if precision {
        x *= 2
        y *= 2
    }
    // Pack scroll mods: precision at bit 0, momentum at bits 1-3.
    // Matches Ghostty's ScrollMods encoding in Ghostty.Input.swift.
    var mods: ghostty_input_scroll_mods_t = 0
    if precision {
        mods |= 1
    }
    let momentum: Int32 = switch event.momentumPhase {
    case .began: 1
    case .stationary: 2
    case .changed: 3
    case .ended: 4
    case .cancelled: 5
    case .mayBegin: 6
    default: 0
    }
    mods |= momentum << 1
    ghostty_surface_mouse_scroll(surface, x, y, mods)
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "feat: include scroll momentum phase in scroll events"
```

---

### Task 7: Mouse pressure release and focus-click suppression

Add pressure release in mouseUp and suppress focus-only clicks.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:311-321` (mouseDown, mouseUp)
- Modify: `Sources/Ghostty/SurfaceView.swift:281-296` (resignFirstResponder)
- Modify: `Sources/Ghostty/SurfaceView.swift:21-57` (add property)

- [ ] **Step 1: Add suppressNextLeftMouseUp property**

Add after line 35 (lastPerformKeyEvent):
```swift
/// When true, suppress the next left mouseUp to avoid sending a release
/// without a matching press (focus-only clicks).
private var suppressNextLeftMouseUp: Bool = false
```

- [ ] **Step 2: Update mouseDown to detect focus-only clicks**

Replace `mouseDown` (lines 311-315):
```swift
override func mouseDown(with event: NSEvent) {
    guard let surface = self.surface else { return }

    // If we're not the first responder, this click is transferring focus.
    // When the app/window is already active, consume the click entirely.
    if window?.firstResponder !== self {
        if NSApp.isActive, window?.isKeyWindow == true {
            window?.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return
        }
        window?.makeFirstResponder(self)
    }

    let mods = Self.ghosttyMods(from: event)
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
}
```

- [ ] **Step 3: Update mouseUp with suppression and pressure release**

Replace `mouseUp` (lines 317-321):
```swift
override func mouseUp(with event: NSEvent) {
    if suppressNextLeftMouseUp {
        suppressNextLeftMouseUp = false
        return
    }
    guard let surface = self.surface else { return }
    let mods = Self.ghosttyMods(from: event)
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    ghostty_surface_mouse_pressure(surface, 0, 0)
}
```

- [ ] **Step 4: Clear suppression on focus loss**

In `resignFirstResponder`, after the existing `ghostty_surface_set_focus` call, add:
```swift
suppressNextLeftMouseUp = false
```

- [ ] **Step 5: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 6: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "feat: add focus-click suppression and mouse pressure release"
```

---

### Task 8: Left/right modifier detection

Update ghosttyMods to detect which side of the keyboard modifiers come from.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:875-883` (ghosttyMods(fromCocoa:))
- Modify: `Sources/Ghostty/SurfaceView.swift:551-574` (flagsChanged)

- [ ] **Step 1: Add right-side modifier detection to ghosttyMods**

Replace `ghosttyMods(fromCocoa:)` (lines 875-883):
```swift
static func ghosttyMods(fromCocoa flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    // Detect right-side modifiers via device-specific masks.
    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(mods)
}
```

- [ ] **Step 2: Add side detection to flagsChanged**

Replace `flagsChanged` (lines 551-574):
```swift
override func flagsChanged(with event: NSEvent) {
    guard self.surface != nil else { return }
    if hasMarkedText() { return }

    let mod: UInt32
    switch event.keyCode {
    case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }

    let mods = Self.ghosttyMods(from: event)

    var action = GHOSTTY_ACTION_RELEASE
    if mods.rawValue & mod != 0 {
        // Check if the correct side is pressed. If the opposite side
        // is held and this side was released, it's still a release.
        let sidePressed: Bool
        switch event.keyCode {
        case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
        default: sidePressed = true
        }
        if sidePressed {
            action = GHOSTTY_ACTION_PRESS
        }
    }

    keyAction(action, event: event)
}
```

- [ ] **Step 3: Add Carbon import if needed**

The `NX_DEVICE*` constants come from IOKit. Check if `import Carbon.HIToolbox` (already at line 2) brings them in. If not, add:
```swift
import IOKit.hidsystem
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "feat: detect left/right modifier keys, matching Ghostty upstream"
```

---

### Task 9: doCommand scroll selectors

Handle scroll-to-top/bottom via doCommand.

**Files:**
- Modify: `Sources/Ghostty/SurfaceView.swift:670-680` (doCommand)

- [ ] **Step 1: Add scroll selector handling**

Replace `doCommand(by:)` (lines 670-680):
```swift
override func doCommand(by selector: Selector) {
    // If we're processing a Cmd+key event that was redispatched by
    // performKeyEquivalent, send it back through the event system
    // so it can be encoded by keyDown.
    if let lastPerformKeyEvent,
       let current = NSApp.currentEvent,
       lastPerformKeyEvent == current.timestamp {
        NSApp.sendEvent(current)
        return
    }

    guard let surface = self.surface else { return }
    switch selector {
    case #selector(moveToBeginningOfDocument(_:)):
        let action = "scroll_to_top"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    case #selector(moveToEndOfDocument(_:)):
        let action = "scroll_to_bottom"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    default:
        break
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Sources/Ghostty/SurfaceView.swift
git commit -m "feat: handle scroll-to-top/bottom via doCommand selectors"
```

---

### Task 10: Final build and smoke test

- [ ] **Step 1: Full build**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Ask user to test**

Ask the user to restart Deckard and verify:
- Tab switching works (no stuck input)
- Typing in multiple tabs works
- Right-clicking shows context menu when appropriate
- Rapid Cmd+T tab creation doesn't deadlock
- Session restore with many tabs doesn't deadlock
