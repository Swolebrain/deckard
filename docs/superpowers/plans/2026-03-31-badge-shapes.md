# Customizable Badge Shapes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to customize the shape of each badge state independently, with 9 shape options and circle as the default.

**Architecture:** Add a `BadgeShape` enum to `TabItem`, a `BadgeShapeView` NSView subclass that draws shapes via `CAShapeLayer`, persistence via UserDefaults following the existing `badgeColor.*` / `badgeAnimate.*` pattern, and an NSPopUpButton column in the settings badge table.

**Tech Stack:** Swift, AppKit (NSView, CAShapeLayer, CGPath, NSPopUpButton)

---

### Task 1: Add BadgeShape enum to TabItem

**Files:**
- Modify: `Sources/Window/DeckardWindowController.swift:24-36`

- [ ] **Step 1: Add BadgeShape enum inside TabItem, after the BadgeState enum**

In `Sources/Window/DeckardWindowController.swift`, add the following enum after the closing brace of `BadgeState` (line 36) and before the `init` (line 38):

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

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Window/DeckardWindowController.swift
git commit -m "feat: add BadgeShape enum to TabItem"
```

---

### Task 2: Create BadgeShapeView and shape path generation

**Files:**
- Modify: `Sources/Window/SidebarViews.swift:1` (add new class at end of file, before the existing `// MARK: - SidebarDropZone` section, or after all existing classes)

- [ ] **Step 1: Add BadgeShapeView class and shapeForBadge helper**

At the end of `Sources/Window/SidebarViews.swift`, after the closing brace of `AddTabButton` (the last class in the file), add:

```swift
// MARK: - BadgeShapeView

/// Draws a badge dot using a CAShapeLayer for customizable shapes.
class BadgeShapeView: NSView {
    private let shapeLayer = CAShapeLayer()

    init(shape: TabItem.BadgeShape, color: NSColor, size: CGFloat = 7) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.addSublayer(shapeLayer)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        updateAppearance(shape: shape, color: color, size: size)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateAppearance(shape: TabItem.BadgeShape, color: NSColor, size: CGFloat = 7) {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        shapeLayer.path = Self.path(for: shape, in: rect)
        shapeLayer.fillColor = color.cgColor
        shapeLayer.frame = rect
    }

    static func path(for shape: TabItem.BadgeShape, in rect: CGRect) -> CGPath {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY

        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)

        case .square:
            // Inset slightly so visual weight matches the circle
            let inset: CGFloat = 0.5
            return CGPath(rect: rect.insetBy(dx: inset, dy: inset), transform: nil)

        case .diamond:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: cy))
            path.addLine(to: CGPoint(x: cx, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: cy))
            path.closeSubpath()
            return path

        case .triangleUp:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path

        case .triangleDown:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
            return path

        case .cross:
            let arm = w * 0.22
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx - arm, y: rect.minY))
            path.addLine(to: CGPoint(x: cx + arm, y: rect.minY))
            path.addLine(to: CGPoint(x: cx + arm, y: cy - arm))
            path.addLine(to: CGPoint(x: rect.maxX, y: cy - arm))
            path.addLine(to: CGPoint(x: rect.maxX, y: cy + arm))
            path.addLine(to: CGPoint(x: cx + arm, y: cy + arm))
            path.addLine(to: CGPoint(x: cx + arm, y: rect.maxY))
            path.addLine(to: CGPoint(x: cx - arm, y: rect.maxY))
            path.addLine(to: CGPoint(x: cx - arm, y: cy + arm))
            path.addLine(to: CGPoint(x: rect.minX, y: cy + arm))
            path.addLine(to: CGPoint(x: rect.minX, y: cy - arm))
            path.addLine(to: CGPoint(x: cx - arm, y: cy - arm))
            path.closeSubpath()
            return path

        case .xCross:
            // Same as cross but rotated 45°
            let arm = w * 0.22
            var transform = CGAffineTransform.identity
                .translatedBy(x: cx, y: cy)
                .rotated(by: .pi / 4)
                .translatedBy(x: -cx, y: -cy)
            let crossPath = Self.path(for: .cross, in: rect)
            return crossPath.copy(using: &transform) ?? crossPath

        case .hexagon:
            let path = CGMutablePath()
            let r = w / 2
            for i in 0..<6 {
                let angle = CGFloat(i) * .pi / 3 - .pi / 6  // flat-top hexagon
                let px = cx + r * cos(angle)
                let py = cy + r * sin(angle)
                if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
                else { path.addLine(to: CGPoint(x: px, y: py)) }
            }
            path.closeSubpath()
            return path

        case .star:
            let path = CGMutablePath()
            let outerR = w / 2
            let innerR = outerR * 0.38
            for i in 0..<10 {
                let angle = CGFloat(i) * .pi / 5 - .pi / 2
                let r = i % 2 == 0 ? outerR : innerR
                let px = cx + r * cos(angle)
                let py = cy + r * sin(angle)
                if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
                else { path.addLine(to: CGPoint(x: px, y: py)) }
            }
            path.closeSubpath()
            return path
        }
    }
}
```

- [ ] **Step 2: Add shapeForBadge helper to VerticalTabRowView**

In `Sources/Window/SidebarViews.swift`, add these two members right after the `colorForBadge` method (after line 182):

```swift
    static func shapeForBadge(_ state: TabItem.BadgeState) -> TabItem.BadgeShape {
        if let raw = UserDefaults.standard.string(forKey: "badgeShape.\(state.rawValue)"),
           let shape = TabItem.BadgeShape(rawValue: raw) {
            return shape
        }
        return .circle
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Window/SidebarViews.swift
git commit -m "feat: add BadgeShapeView and shape path generation"
```

---

### Task 3: Use BadgeShapeView in sidebar badge dots

**Files:**
- Modify: `Sources/Window/SidebarViews.swift:107-127` (VerticalTabRowView.updateBadgeDots)
- Modify: `Sources/Window/SidebarViews.swift:484-508` (SidebarFolderView.updateBadgeDots)

- [ ] **Step 1: Replace plain NSView dots with BadgeShapeView in VerticalTabRowView.updateBadgeDots**

In `Sources/Window/SidebarViews.swift`, replace the body of `updateBadgeDots()` in `VerticalTabRowView` (the `for info in badgeInfos` loop, currently lines 112-127). Replace:

```swift
        for info in badgeInfos where info.state != .none {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = Self.colorForBadge(info.state).cgColor
            dot.toolTip = "\(info.name): \(Self.tooltipForBadge(info.state, activity: info.activity))"
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if SettingsWindowController.isBadgeAnimated(info.state) {
                Self.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
```

With:

```swift
        for info in badgeInfos where info.state != .none {
            let dot = BadgeShapeView(
                shape: Self.shapeForBadge(info.state),
                color: Self.colorForBadge(info.state)
            )
            dot.toolTip = "\(info.name): \(Self.tooltipForBadge(info.state, activity: info.activity))"
            if SettingsWindowController.isBadgeAnimated(info.state) {
                Self.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
```

- [ ] **Step 2: Replace plain NSView dots with BadgeShapeView in SidebarFolderView.updateBadgeDots**

In the same file, replace the `for info in badgeInfos` loop inside `SidebarFolderView.updateBadgeDots()` (currently lines 492-507). Replace:

```swift
        for info in badgeInfos where info.state != .none {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = VerticalTabRowView.colorForBadge(info.state).cgColor
            dot.toolTip = "\(info.name): \(VerticalTabRowView.tooltipForBadge(info.state, activity: info.activity))"
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if SettingsWindowController.isBadgeAnimated(info.state) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
```

With:

```swift
        for info in badgeInfos where info.state != .none {
            let dot = BadgeShapeView(
                shape: VerticalTabRowView.shapeForBadge(info.state),
                color: VerticalTabRowView.colorForBadge(info.state)
            )
            dot.toolTip = "\(info.name): \(VerticalTabRowView.tooltipForBadge(info.state, activity: info.activity))"
            if SettingsWindowController.isBadgeAnimated(info.state) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Window/SidebarViews.swift
git commit -m "feat: use BadgeShapeView for sidebar badge dots"
```

---

### Task 4: Use BadgeShapeView in horizontal tab bar

**Files:**
- Modify: `Sources/Window/TabBarViews.swift:49-67`

- [ ] **Step 1: Replace plain NSView dot with BadgeShapeView in HorizontalTabView**

In `Sources/Window/TabBarViews.swift`, replace the badge dot creation block (lines 50-67). Replace:

```swift
        if badgeState != .none {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = VerticalTabRowView.colorForBadge(badgeState).cgColor
            dot.toolTip = VerticalTabRowView.tooltipForBadge(badgeState, activity: activity)
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            if SettingsWindowController.isBadgeAnimated(badgeState) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeDot = dot
        }
```

With:

```swift
        if badgeState != .none {
            let dot = BadgeShapeView(
                shape: VerticalTabRowView.shapeForBadge(badgeState),
                color: VerticalTabRowView.colorForBadge(badgeState)
            )
            dot.toolTip = VerticalTabRowView.tooltipForBadge(badgeState, activity: activity)
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            if SettingsWindowController.isBadgeAnimated(badgeState) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeDot = dot
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Window/TabBarViews.swift
git commit -m "feat: use BadgeShapeView for horizontal tab bar badges"
```

---

### Task 5: Add shape picker column to settings badge table

**Files:**
- Modify: `Sources/Window/SettingsWindow.swift:710-853` (makeBadgeColorGrid and related methods)

- [ ] **Step 1: Add a Shape column to the badge table**

In `Sources/Window/SettingsWindow.swift`, inside the `makeSectionTable` closure of `makeBadgeColorGrid()`, make these changes:

**a)** Change column widths (line 716). Replace:

```swift
            let colWidths: [CGFloat] = [120, 50, 50]  // state, color, blink
```

With:

```swift
            let colWidths: [CGFloat] = [120, 100, 50, 50]  // state, shape, color, blink
```

**b)** Update the header row labels (lines 781-786). Replace:

```swift
            var x: CGFloat = 0
            placeLabel("State", x: x, y: 0, width: colWidths[0], bold: true)
            x += colWidths[0]
            placeLabel("Color", x: x, y: 0, width: colWidths[1], bold: true)
            x += colWidths[1]
            placeLabel("Blink", x: x, y: 0, width: colWidths[2], bold: true)
```

With:

```swift
            var x: CGFloat = 0
            placeLabel("State", x: x, y: 0, width: colWidths[0], bold: true)
            x += colWidths[0]
            placeLabel("Shape", x: x, y: 0, width: colWidths[1], bold: true)
            x += colWidths[1]
            placeLabel("Color", x: x, y: 0, width: colWidths[2], bold: true)
            x += colWidths[2]
            placeLabel("Blink", x: x, y: 0, width: colWidths[3], bold: true)
```

**c)** In the data rows loop (lines 798-815), add the shape popup and shift color/blink columns. Replace the loop body:

```swift
            for (ei, entry) in entries.enumerated() {
                let y = CGFloat(ei + 1) * rowHeight

                placeLabel(entry.label, x: 0, y: y, width: colWidths[0])

                let well = makeBadgeColorWell(for: entry.state)
                placeView(well, x: colWidths[0], y: y, width: colWidths[1])

                let toggle = NSButton(checkboxWithTitle: "", target: self,
                                      action: #selector(badgeAnimateChanged(_:)))
                toggle.state = Self.isBadgeAnimated(entry.state) ? .on : .off
                toggle.controlSize = .small
                objc_setAssociatedObject(toggle, &settingsKeyAssoc,
                                         entry.state.rawValue, .OBJC_ASSOCIATION_RETAIN)
                placeView(toggle, x: colWidths[0] + colWidths[1], y: y, width: colWidths[2])

                addHLine(y: y + rowHeight)
            }
```

With:

```swift
            for (ei, entry) in entries.enumerated() {
                let y = CGFloat(ei + 1) * rowHeight

                placeLabel(entry.label, x: 0, y: y, width: colWidths[0])

                let shapePopup = makeBadgeShapePopup(for: entry.state)
                placeView(shapePopup, x: colWidths[0], y: y, width: colWidths[1])

                let well = makeBadgeColorWell(for: entry.state)
                placeView(well, x: colWidths[0] + colWidths[1], y: y, width: colWidths[2])

                let toggle = NSButton(checkboxWithTitle: "", target: self,
                                      action: #selector(badgeAnimateChanged(_:)))
                toggle.state = Self.isBadgeAnimated(entry.state) ? .on : .off
                toggle.controlSize = .small
                objc_setAssociatedObject(toggle, &settingsKeyAssoc,
                                         entry.state.rawValue, .OBJC_ASSOCIATION_RETAIN)
                placeView(toggle, x: colWidths[0] + colWidths[1] + colWidths[2], y: y, width: colWidths[3])

                addHLine(y: y + rowHeight)
            }
```

- [ ] **Step 2: Add makeBadgeShapePopup and badgeShapeChanged methods**

In `Sources/Window/SettingsWindow.swift`, right after the `makeBadgeColorWell(for:)` method (after line 873), add:

```swift
    private func makeBadgeShapePopup(for state: TabItem.BadgeState) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            popup.widthAnchor.constraint(equalToConstant: 90),
        ])
        for shape in TabItem.BadgeShape.allCases {
            popup.addItem(withTitle: shape.displayName)
        }
        let current = VerticalTabRowView.shapeForBadge(state)
        popup.selectItem(withTitle: current.displayName)
        objc_setAssociatedObject(popup, &settingsKeyAssoc, state.rawValue, .OBJC_ASSOCIATION_RETAIN)
        popup.target = self
        popup.action = #selector(badgeShapeChanged(_:))
        return popup
    }

    @objc private func badgeShapeChanged(_ sender: NSPopUpButton) {
        guard let stateRaw = objc_getAssociatedObject(sender, &settingsKeyAssoc) as? String,
              let selectedTitle = sender.titleOfSelectedItem,
              let shape = TabItem.BadgeShape.allCases.first(where: { $0.displayName == selectedTitle }) else { return }
        UserDefaults.standard.set(shape.rawValue, forKey: "badgeShape.\(stateRaw)")
        if let wc = NSApp.delegate as? AppDelegate {
            wc.windowController?.rebuildSidebar()
            wc.windowController?.rebuildTabBar()
        }
    }
```

- [ ] **Step 3: Update resetBadgeColors to also reset shapes**

In `Sources/Window/SettingsWindow.swift`, in the `resetBadgeColors()` method (line 894-905), add shape key removal. Replace:

```swift
    @objc private func resetBadgeColors() {
        for entry in Self.claudeBadgeEntries + Self.terminalBadgeEntries {
            UserDefaults.standard.removeObject(forKey: "badgeColor.\(entry.state.rawValue)")
            UserDefaults.standard.removeObject(forKey: "badgeAnimate.\(entry.state.rawValue)")
        }
```

With:

```swift
    @objc private func resetBadgeColors() {
        for entry in Self.claudeBadgeEntries + Self.terminalBadgeEntries {
            UserDefaults.standard.removeObject(forKey: "badgeColor.\(entry.state.rawValue)")
            UserDefaults.standard.removeObject(forKey: "badgeAnimate.\(entry.state.rawValue)")
            UserDefaults.standard.removeObject(forKey: "badgeShape.\(entry.state.rawValue)")
        }
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/Window/SettingsWindow.swift
git commit -m "feat: add shape picker column to badge settings table"
```

---

### Task 6: Manual verification and final commit

- [ ] **Step 1: Build the app**

Run:
```bash
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Ask user to launch and verify**

Ask the user to launch Deckard and verify:
1. Settings > Theme pane shows the new Shape column with dropdowns
2. Changing a shape in settings immediately updates the sidebar and tab bar badges
3. Each badge state can have a different shape
4. Reset to Defaults restores all shapes to Circle
5. Shapes persist across app restart (quit and relaunch)
6. Pulse animation still works on shaped badges (Thinking, Terminal Busy)

- [ ] **Step 3: Squash into a single feature commit (if user prefers)**

If the user wants a single commit, squash the task commits. Otherwise, the incremental commits are fine.
