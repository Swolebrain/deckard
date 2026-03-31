# Customizable Badge Shapes

## Summary

Allow users to customize the shape of per-state badges, just like they can already customize color and blinking. Each badge state can have an independent shape. The default for all states is circle (preserving current behavior).

## Shapes

Nine shapes, all fitted to the same 7×7 bounding box:

| Shape | Enum case | Description |
|-------|-----------|-------------|
| Circle | `circle` | Current default. Full circle. |
| Square | `square` | Sharp-cornered square. |
| Diamond | `diamond` | 45° rotated square. |
| Triangle Up | `triangleUp` | Upward-pointing equilateral triangle. |
| Triangle Down | `triangleDown` | Downward-pointing equilateral triangle. |
| Cross (+) | `cross` | Vertical/horizontal cross. |
| X Cross (×) | `xCross` | 45° rotated cross. |
| Hexagon | `hexagon` | Regular six-sided polygon. |
| Star | `star` | Five-pointed star. |

## Model

### BadgeShape enum

Add `BadgeShape` as a nested enum inside `TabItem`, alongside `BadgeState`:

```swift
enum BadgeShape: String, CaseIterable {
    case circle, square, diamond, triangleUp, triangleDown, cross, xCross, hexagon, star

    var displayName: String {
        switch self {
        case .circle: return "Circle"
        case .square: return "Square"
        case .diamond: return "Diamond"
        case .triangleUp: return "Triangle ▲"
        case .triangleDown: return "Triangle ▼"
        case .cross: return "Cross +"
        case .xCross: return "Cross ×"
        case .hexagon: return "Hexagon"
        case .star: return "Star"
        }
    }
}
```

File: `DeckardWindowController.swift`

## Storage

Same pattern as badge colors and blink toggles:

- **Key:** `badgeShape.<BadgeState.rawValue>` (e.g. `badgeShape.thinking`)
- **Value:** `BadgeShape.rawValue` string
- **Default:** `circle` for all states

Static helpers on `VerticalTabRowView`:

```swift
static let defaultBadgeShapes: [TabItem.BadgeState: TabItem.BadgeShape] = [:]
// Empty — all states default to .circle when no override exists.

static func shapeForBadge(_ state: TabItem.BadgeState) -> TabItem.BadgeShape {
    if let raw = UserDefaults.standard.string(forKey: "badgeShape.\(state.rawValue)"),
       let shape = TabItem.BadgeShape(rawValue: raw) {
        return shape
    }
    return defaultBadgeShapes[state] ?? .circle
}
```

File: `SidebarViews.swift`

## Drawing

### BadgeShapeView

New `NSView` subclass that replaces the current plain `NSView` + `cornerRadius` dot. Uses a `CAShapeLayer` to draw the shape path.

```
BadgeShapeView
├── Properties: shape (BadgeShape), color (NSColor)
├── init(shape:color:size:) — size defaults to 7
├── updateAppearance(shape:color:) — updates path and fill
└── Static: path(for:in:) -> CGPath — returns shape path for given rect
```

Each shape's `CGPath` is computed to fit within the provided `CGRect` (7×7 by default). Shapes are designed so their visual weight is comparable — e.g., the star and cross are slightly larger than the circle to compensate for negative space.

The pulse animation (`addPulseAnimation`) animates `opacity` on the layer and works unchanged since `CAShapeLayer` inherits from `CALayer`.

File: `SidebarViews.swift`

### Integration points

Both badge-drawing sites switch from creating a plain `NSView` with `cornerRadius` to creating a `BadgeShapeView`:

1. **`SidebarViews.swift`** — `VerticalTabRowView` and `SidebarFolderView` dot creation
2. **`TabBarViews.swift`** — `HorizontalTabView` dot creation

The shape is determined by calling `VerticalTabRowView.shapeForBadge(state)` at the same point where `colorForBadge(state)` is already called.

## Settings UI

### Layout change

The badge customization table in the Theme pane gains a 4th column:

```
State (120pt) | Shape (100pt) | Color (50pt) | Blink (50pt)
```

Shape column uses an `NSPopUpButton` per row, populated from `BadgeShape.allCases` with `displayName` titles. The popup's selected item reflects the current persisted (or default) shape.

### Interactions

- Selecting a shape from the popup writes `badgeShape.<state>` to UserDefaults
- The "Reset" button also clears all `badgeShape.*` keys, restoring circle defaults
- The preview dot next to each row updates its shape in real time (the existing color-well action already rebuilds the dot; shape popup does the same)

File: `SettingsWindow.swift`

## Files changed

| File | Changes |
|------|---------|
| `Sources/Window/DeckardWindowController.swift` | Add `BadgeShape` enum inside `TabItem` |
| `Sources/Window/SidebarViews.swift` | Add `BadgeShapeView` class, `shapeForBadge()`, `defaultBadgeShapes`, update dot creation |
| `Sources/Window/TabBarViews.swift` | Update dot creation to use `BadgeShapeView` |
| `Sources/Window/SettingsWindow.swift` | Add shape popup column, persist/load/reset shape per state |

## Non-goals

- Shape animation (morphing between shapes on state change) — out of scope
- Per-tab shape overrides — shapes are per-state, not per-tab
- Shape previews in the popup menu items — just text labels for now
