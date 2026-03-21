import Foundation

/// Lightweight diagnostic logger that writes to ~/Library/Application Support/Deckard/diagnostic.log.
/// Thread-safe via serial dispatch queue. Truncates on launch if > 200 KB.
class DiagnosticLog {
    static let shared = DiagnosticLog()

    private let queue = DispatchQueue(label: "com.deckard.diagnostic-log")
    private let fileURL: URL
    private let handle: FileHandle?
    private let formatter: DateFormatter
    private let buildTag: String

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        fileURL = dir.appendingPathComponent("diagnostic.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        // Use executable mod date as build timestamp (changes on every recompile).
        var buildDate = "?"
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            let df = DateFormatter()
            df.dateFormat = "MMdd-HHmm"
            buildDate = df.string(from: modDate)
        }
        buildTag = "v\(version)(\(build))-\(buildDate)"

        // Create file if needed
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        // Truncate if > 200 KB: keep the last 100 KB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64, size > 200_000 {
            if let data = try? Data(contentsOf: fileURL) {
                let keep = data.suffix(100_000)
                // Find first newline to avoid partial line
                if let nl = keep.firstIndex(of: UInt8(ascii: "\n")) {
                    let trimmed = keep.suffix(from: keep.index(after: nl))
                    try? trimmed.write(to: fileURL)
                }
            }
        }

        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()

        // Write a session header so we can distinguish app launches in the log.
        if let handle {
            let ts = formatter.string(from: Date())
            let header = "\n[\(ts)] [startup] === Deckard \(buildTag) launched ===\n"
            if let data = header.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    func log(_ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            let ts = self.formatter.string(from: Date())
            let line = "[\(ts)] [\(category)] [\(self.buildTag)] \(message)\n"
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }
}
