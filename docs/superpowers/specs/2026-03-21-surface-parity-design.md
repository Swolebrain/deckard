# Surface Handling Parity: Deckard ← Ghostty

## Problem

Deckard's Ghostty surface handling diverged from upstream in several ways that introduced bugs (stuck input, event races, missing mouse features) and unnecessary complexity (surfaceQueue threading model). Surfaces never get stuck in Ghostty or cmux — the bugs are Deckard-specific.

A prior change in this session replaced hide/unhide tab switching with z-ordering, eliminating the hidden-surface initialization gap that was the root cause of stuck input. This spec addresses the remaining differences.

## Reference Files

- **Deckard**: `Sources/Ghostty/SurfaceView.swift`, `Sources/Ghostty/DeckardGhosttyApp.swift`
- **Ghostty**: `ghostty/macos/Sources/Ghostty/SurfaceView_AppKit.swift`, `ghostty/macos/Sources/Ghostty/Ghostty.App.swift`, `ghostty/macos/Sources/Ghostty/Ghostty.Surface.swift`, `ghostty/macos/Sources/Ghostty/Ghostty.Input.swift`

---

## Section 1: Remove surfaceQueue, Return to Main-Thread Calls

### Background

Three commits (f4b9992, 7888d19, 255003e) introduced progressively more off-main-thread dispatching to avoid deadlocking with libghostty's renderer/IO lock. The deadlocks were triggered by Deckard's hide/unhide tab switching and rapid session-restore surface creation — patterns that Ghostty's native app never exercises.

With z-ordering (surfaces always visible, never hidden), the primary deadlock triggers are gone.

### Change

Remove the `surfaceQueue` serial dispatch queue from `TerminalNSView`. Call all `ghostty_surface_*` functions directly on the main thread, matching Ghostty:

- `ghostty_surface_key()` — synchronous, restoring the return value
- `ghostty_surface_set_focus()` — synchronous in `becomeFirstResponder`/`resignFirstResponder` (note: these are currently on `DispatchQueue.global(qos: .userInteractive)`, not even on the surfaceQueue — an inconsistency that makes them less safe than the serial queue pattern)
- `ghostty_surface_set_size()`, `ghostty_surface_set_content_scale()` — synchronous
- `ghostty_surface_preedit()`, `ghostty_surface_text()` — synchronous

**Exception**: Keep `ghostty_surface_free()` off the main thread. Ghostty defers this via `Task.detached { @MainActor in }` (deferred main-thread execution, not synchronous in deinit). Deckard dispatches to a background queue. Both avoid synchronous free during deinit; Deckard's approach has been stable, so keep it.

Also move `reloadConfigWithTheme()` in `DeckardGhosttyApp.swift` back to the main thread. It currently dispatches `ghostty_app_update_config` and `ghostty_surface_update_config` to a background queue with the same deadlock-avoidance rationale. Same fix applies.

### What This Fixes

- Mouse/key event race (mouse on main thread, keys on surfaceQueue)
- Key event ordering (async dispatch could reorder rapid keystrokes)
- Preedit out-of-order with text input during rapid IME composition
- `lastSuccessfulCharKeyTime` cross-thread read (written on surfaceQueue, read on main thread)
- `keyAction` return value lost (async dispatch made it impossible to return the bool from `ghostty_surface_key`)

### Risk

If a deadlock recurs, we'll know exactly which `ghostty_surface_*` call triggers it and can selectively move just that one off main thread. The z-order change should prevent recurrence. Scenarios to monitor:
- Launching with 10+ saved tabs restoring simultaneously
- Rapid Cmd+T creating multiple tabs in sequence
- Switching tabs rapidly via keyboard while surfaces are still initializing

---

## Section 2: Add Focused Guard to performKeyEquivalent

### Background

With z-ordering, all surfaces remain in the view hierarchy and the responder chain simultaneously. Without a guard, a background surface could intercept key equivalents meant for the active surface on top.

Ghostty checks `if !focused { return false }` at the top of `performKeyEquivalent`.

### Change

Add a first-responder check at the top of `performKeyEquivalent`:

```swift
guard window?.firstResponder === self else { return false }
```

This is simpler than Ghostty's `focused` property — it checks actual first-responder status directly, with no state to keep in sync. There is a theoretical timing gap between `resignFirstResponder` on one view and `becomeFirstResponder` on the next, but in practice `performKeyEquivalent` is called during event dispatch, not between responder transitions.

---

## Section 3: Mouse Event Parity

Five changes, ordered by impact:

### A. Right-Click Consumption

Check the return value of `ghostty_surface_mouse_button()` in `rightMouseDown` and `rightMouseUp`. If Ghostty didn't consume the event, call `super` so macOS can show context menus.

### B. Mouse Button Mapping

Replace the `buttonNumber == 2` hardcoding in `otherMouseDown`/`otherMouseUp`/`otherMouseDragged` with a mapping function matching Ghostty's `MouseButton.init(fromNSEventButtonNumber:)` in `Ghostty.Input.swift`. The NSEvent-to-Ghostty button mapping is non-trivial (e.g., NSEvent button 3 maps to Ghostty button 8 "Back"), so reference Ghostty's mapping table directly rather than guessing.

### C. Scroll Momentum Phase

Include `event.momentumPhase` in the scroll mods passed to `ghostty_surface_mouse_scroll()`. This requires converting `NSEvent.Phase` to Ghostty's momentum encoding (precision bit at position 0, momentum bits at positions 1-3), matching the encoding in `Ghostty.Input.swift`.

### D. Mouse Pressure Tracking

Call `ghostty_surface_mouse_pressure()` in `mouseUp` with hardcoded `(0, 0)` to release pressure, matching Ghostty (which always passes zeros in mouseUp, not the event's actual values). Enables proper pressure lifecycle on trackpads. The full `pressureChange(with:)` override with QuickLook integration is out of scope for now — it requires `prevPressureStage` state tracking and is a minor feature.

### E. Focus-Click Suppression

Add Ghostty's `suppressNextLeftMouseUp` flag. When the window receives focus via a mouse click, suppress the corresponding mouseUp so the click only focuses without triggering a terminal action. Clear the flag in `resignFirstResponder` (Deckard's equivalent of Ghostty's `focusDidChange` on focus-loss) to prevent the flag from staying set if focus is lost before mouseUp arrives.

---

## Section 4: Input Handling Parity

### A. Left/Right Modifier Detection

Update `ghosttyMods(fromCocoa:)` to detect which side of the keyboard a modifier came from using `NX_DEVICE*KEYMASK` constants, matching Ghostty's implementation in `Ghostty.Input.swift`. This affects **all** key and mouse events (every call to `ghosttyMods`), not just `flagsChanged` — the right-side modifier bits (`GHOSTTY_MODS_*_RIGHT`) are currently missing from all event translation.

### B. doCommand Scroll Selectors

Handle `moveToBeginningOfDocument:` and `moveToEndOfDocument:` in `doCommand(by:)` by calling the appropriate Ghostty scroll actions, matching Ghostty's behavior for Cmd+Home / Cmd+End type bindings.

---

## Out of Scope (Future)

- **`ghostty_surface_set_display_id`** — Ghostty calls this when the window changes screens for CVDisplayLink vsync on multi-monitor setups. Not currently causing issues.
- **Full `pressureChange(with:)` override** — Requires `prevPressureStage` tracking and QuickLook integration. The `mouseUp` pressure call covers the basic case.

---

## Implementation Order

1. Section 1 (surfaceQueue removal) — highest impact, eliminates an entire class of bugs
2. Section 2 (performKeyEquivalent guard) — required for correctness with z-ordering
3. Section 3 (mouse parity) — behavioral correctness, ordered A through E by impact
4. Section 4 (input parity) — polish, lowest urgency
