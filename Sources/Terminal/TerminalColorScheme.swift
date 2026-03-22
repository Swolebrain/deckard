import AppKit
import SwiftTerm

/// A complete terminal color scheme parsed from a Ghostty theme file.
struct TerminalColorScheme {
    let background: NSColor
    let foreground: NSColor
    let palette: [NSColor]          // 16 ANSI colors (indices 0-15)
    let cursorColor: NSColor?
    let cursorTextColor: NSColor?
    let selectionBackground: NSColor?

    /// Apply this color scheme to a SwiftTerm terminal view.
    func apply(to view: LocalProcessTerminalView) {
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground

        if palette.count == 16 {
            view.installColors(palette.map { color in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
                return Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
            })
        }

        if let c = cursorColor { view.caretColor = c }
        if let c = cursorTextColor { view.caretTextColor = c }
        if let c = selectionBackground { view.selectedTextBackgroundColor = c }
    }

    /// Default dark scheme (used when no theme is selected).
    static let `default` = TerminalColorScheme(
        background: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        foreground: NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        palette: [],
        cursorColor: nil,
        cursorTextColor: nil,
        selectionBackground: nil
    )

    // MARK: - Ghostty Theme Parser

    /// Parse a Ghostty theme file into a TerminalColorScheme.
    static func parse(from path: String) -> TerminalColorScheme? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        var bg: NSColor?
        var fg: NSColor?
        var palette = [Int: NSColor]()
        var cursor: NSColor?
        var cursorText: NSColor?
        var selBg: NSColor?

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "background":
                bg = parseHex(value)
            case "foreground":
                fg = parseHex(value)
            case "cursor-color":
                cursor = parseHex(value)
            case "cursor-text":
                cursorText = parseHex(value)
            case "selection-background":
                selBg = parseHex(value)
            case "selection-foreground":
                break // SwiftTerm doesn't support this
            default:
                // Handle "palette = N=#RRGGBB" — key is "palette", value is "N=#RRGGBB"
                if key == "palette" {
                    let parts = value.split(separator: "=", maxSplits: 1)
                    if parts.count == 2,
                       let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       idx >= 0, idx < 16,
                       let color = parseHex(parts[1].trimmingCharacters(in: .whitespaces)) {
                        palette[idx] = color
                    }
                }
            }
        }

        guard let background = bg, let foreground = fg else { return nil }

        // Build palette array — fill missing indices with defaults
        let defaultPalette = defaultAnsiColors()
        let paletteArray = (0..<16).map { palette[$0] ?? defaultPalette[$0] }

        return TerminalColorScheme(
            background: background,
            foreground: foreground,
            palette: paletteArray,
            cursorColor: cursor,
            cursorTextColor: cursorText,
            selectionBackground: selBg
        )
    }

    /// Parse a hex color string like "#282a36" or "282a36".
    private static func parseHex(_ hex: String) -> NSColor? {
        var str = hex
        if str.hasPrefix("#") { str = String(str.dropFirst()) }
        guard str.count == 6, let val = UInt64(str, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((val >> 16) & 0xFF) / 255.0,
            green: CGFloat((val >> 8) & 0xFF) / 255.0,
            blue: CGFloat(val & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// Default ANSI 16-color palette (xterm).
    private static func defaultAnsiColors() -> [NSColor] {
        [
            NSColor(red: 0, green: 0, blue: 0, alpha: 1),           // 0: Black
            NSColor(red: 0.8, green: 0, blue: 0, alpha: 1),         // 1: Red
            NSColor(red: 0, green: 0.8, blue: 0, alpha: 1),         // 2: Green
            NSColor(red: 0.8, green: 0.8, blue: 0, alpha: 1),       // 3: Yellow
            NSColor(red: 0, green: 0, blue: 0.8, alpha: 1),         // 4: Blue
            NSColor(red: 0.8, green: 0, blue: 0.8, alpha: 1),       // 5: Magenta
            NSColor(red: 0, green: 0.8, blue: 0.8, alpha: 1),       // 6: Cyan
            NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),  // 7: White
            NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),     // 8: Bright Black
            NSColor(red: 1, green: 0, blue: 0, alpha: 1),           // 9: Bright Red
            NSColor(red: 0, green: 1, blue: 0, alpha: 1),           // 10: Bright Green
            NSColor(red: 1, green: 1, blue: 0, alpha: 1),           // 11: Bright Yellow
            NSColor(red: 0, green: 0, blue: 1, alpha: 1),           // 12: Bright Blue
            NSColor(red: 1, green: 0, blue: 1, alpha: 1),           // 13: Bright Magenta
            NSColor(red: 0, green: 1, blue: 1, alpha: 1),           // 14: Bright Cyan
            NSColor(red: 1, green: 1, blue: 1, alpha: 1),           // 15: Bright White
        ]
    }
}
