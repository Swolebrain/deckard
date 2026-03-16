import AppKit

/// Manages Ghostty theme enumeration, selection, and config override.
class ThemeManager {
    static let shared = ThemeManager()

    struct ThemeInfo {
        let name: String
        let path: String
    }

    private(set) var availableThemes: [ThemeInfo] = []
    var currentColors: ThemeColors = .default

    /// The persisted theme name (nil = system default).
    var currentThemeName: String? {
        UserDefaults.standard.string(forKey: "ghosttyThemeName")
    }

    /// Path to the override config file that sets the theme.
    let overrideConfigPath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ghostty-theme-override").path
    }()

    // MARK: - Theme Discovery

    func loadAvailableThemes() {
        var themes: [ThemeInfo] = []
        var seen = Set<String>()

        // Search paths for Ghostty themes (checked in order of priority)
        var searchDirs: [String] = []

        // 1. Bundled themes (shipped with Deckard in the app bundle)
        if let bundledThemes = Bundle.main.resourceURL?.appendingPathComponent("themes").path {
            searchDirs.append(bundledThemes)
        }

        // 2. User custom themes
        searchDirs.append(NSHomeDirectory() + "/.config/ghostty/themes")

        for dir in searchDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where !seen.contains(file) {
                seen.insert(file)
                let path = (dir as NSString).appendingPathComponent(file)
                themes.append(ThemeInfo(name: file, path: path))
            }
        }

        themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        availableThemes = themes
    }

    // MARK: - Theme Application

    func applyTheme(name: String?) {
        if let name = name,
           let theme = availableThemes.first(where: { $0.name == name }),
           let themeContent = try? String(contentsOfFile: theme.path, encoding: .utf8) {
            // Write the full theme file content as the override (raw color values).
            // Using `theme = <name>` requires Ghostty to resolve the theme path,
            // which may not work reliably with ghostty_config_load_file.
            try? themeContent.write(toFile: overrideConfigPath, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(name, forKey: "ghosttyThemeName")
        } else {
            // System Default — remove override
            try? FileManager.default.removeItem(atPath: overrideConfigPath)
            UserDefaults.standard.removeObject(forKey: "ghosttyThemeName")
        }

        // Reload Ghostty config so terminals pick up the new theme
        DeckardGhosttyApp.instance?.reloadConfigWithTheme()

        // Read colors directly from the theme file for chrome adaptation
        let bg: NSColor
        let fg: NSColor
        if let name = name,
           let theme = availableThemes.first(where: { $0.name == name }),
           let colors = Self.parseThemeColors(at: theme.path) {
            bg = colors.background
            fg = colors.foreground
        } else if let app = DeckardGhosttyApp.instance {
            bg = app.defaultBackgroundColor
            fg = app.defaultForegroundColor
        } else {
            bg = .windowBackgroundColor
            fg = .labelColor
        }

        updateColors(background: bg, foreground: fg)
    }

    func updateColors(background: NSColor, foreground: NSColor) {
        currentColors = ThemeColors(background: background, foreground: foreground)
        NotificationCenter.default.post(
            name: .deckardThemeChanged,
            object: nil,
            userInfo: ["colors": currentColors]
        )
    }

    // MARK: - Theme File Parsing

    /// Parse background and foreground colors from a Ghostty theme file.
    static func parseThemeColors(at path: String) -> (background: NSColor, foreground: NSColor)? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        var bg: NSColor?
        var fg: NSColor?

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("background") && !trimmed.hasPrefix("background-") {
                if let color = parseColorValue(from: trimmed) { bg = color }
            } else if trimmed.hasPrefix("foreground") {
                if let color = parseColorValue(from: trimmed) { fg = color }
            }
        }

        guard let background = bg, let foreground = fg else { return nil }
        return (background, foreground)
    }

    /// Parse a color from a line like "background = #282a36"
    private static func parseColorValue(from line: String) -> NSColor? {
        guard let eqIdx = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
        return parseHexColor(value)
    }

    /// Parse a hex color string like "#282a36" or "282a36"
    private static func parseHexColor(_ hex: String) -> NSColor? {
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
}

extension Notification.Name {
    static let deckardThemeChanged = Notification.Name("deckardThemeChanged")
}
