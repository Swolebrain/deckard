import AppKit

// Install crash handlers as early as possible.
CrashReporter.install()
DiagnosticLog.shared.log("startup", "=== Deckard launch ===")
DiagnosticLog.shared.log("startup", "PID: \(ProcessInfo.processInfo.processIdentifier)")

// Surface any crash report left by a previous run.
CrashReporter.logPreviousCrashIfAny()

// Launch the macOS application.
DiagnosticLog.shared.log("startup", "Creating NSApplication...")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
DiagnosticLog.shared.log("startup", "Entering app.run()")
app.run()
