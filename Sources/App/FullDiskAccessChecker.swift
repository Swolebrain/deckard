import AppKit

enum FullDiskAccessChecker {
    /// Checks whether Full Disk Access has been granted by spawning a
    /// subprocess that accesses an FDA-protected path.  TCC attributes
    /// child-process file access to the parent app, which registers
    /// Deckard under kTCCServiceSystemPolicyAllFiles (the FDA service).
    /// Direct FileManager calls go through framework XPC helpers that
    /// trigger different, more specific TCC services instead.
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedPaths = [
            home + "/Library/Safari",
            home + "/Library/Mail",
        ]
        for path in protectedPaths {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ls")
            process.arguments = [path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return true   // FDA granted
                }
                return false      // ls failed (permission denied) — probe registered us
            } catch {
                continue          // /bin/ls not found or other launch error
            }
        }
        return false
    }

    /// Opens System Settings to the Full Disk Access pane and reveals
    /// Deckard.app in Finder so the user can drag it into the list or
    /// select it via the "+" button.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }
}
