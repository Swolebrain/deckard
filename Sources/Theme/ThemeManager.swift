import AppKit

/// Manages terminal theme enumeration, selection, and application.
/// Themes are Ghostty-format config files with color definitions.
class ThemeManager {
    static let shared = ThemeManager()

    struct ThemeInfo {
        let name: String
        let path: String
    }

    private(set) var availableThemes: [ThemeInfo] = []
    var currentColors: ThemeColors = .default
    var currentScheme: TerminalColorScheme = .default

    /// The persisted theme name (nil = system default).
    var currentThemeName: String? {
        UserDefaults.standard.string(forKey: "ghosttyThemeName")
    }

    // MARK: - Theme Discovery

    func loadAvailableThemes() {
        var themes: [ThemeInfo] = []
        var seen = Set<String>()

        var searchDirs: [String] = []

        // 1. Bundled themes (shipped with Deckard)
        if let bundledThemes = Bundle.main.resourceURL?.appendingPathComponent("themes").path {
            searchDirs.append(bundledThemes)
        }

        // 2. User custom themes
        searchDirs.append(NSHomeDirectory() + "/.config/ghostty/themes")

        for dir in searchDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where !file.hasPrefix(".") && !file.hasPrefix("LICENSE") && !seen.contains(file) {
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
        let scheme: TerminalColorScheme
        if let name = name,
           let theme = availableThemes.first(where: { $0.name == name }),
           let parsed = TerminalColorScheme.parse(from: theme.path) {
            scheme = parsed
            UserDefaults.standard.set(name, forKey: "ghosttyThemeName")
        } else {
            scheme = .default
            UserDefaults.standard.removeObject(forKey: "ghosttyThemeName")
        }

        currentScheme = scheme
        currentColors = ThemeColors(background: scheme.background, foreground: scheme.foreground)

        NotificationCenter.default.post(
            name: .deckardThemeChanged,
            object: nil,
            userInfo: ["scheme": scheme, "colors": currentColors]
        )
    }

    /// Apply the saved theme (call during startup).
    func applySavedTheme() {
        if let name = currentThemeName,
           let theme = availableThemes.first(where: { $0.name == name }),
           let parsed = TerminalColorScheme.parse(from: theme.path) {
            currentScheme = parsed
            currentColors = ThemeColors(background: parsed.background, foreground: parsed.foreground)
        }
    }
}

extension Notification.Name {
    static let deckardThemeChanged = Notification.Name("deckardThemeChanged")
}
