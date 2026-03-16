import Foundation

/// Reads Claude Code session JSONL files to calculate context usage.
class ContextMonitor {
    static let shared = ContextMonitor()

    private let contextLimits: [String: Int] = [
        "claude-opus-4-6": 1_000_000,
        "claude-sonnet-4-6": 200_000,
        "claude-haiku-4-5": 200_000,
        "claude-haiku-4-5-20251001": 200_000,
    ]
    private let defaultLimit = 200_000

    struct ContextUsage {
        let model: String
        let inputTokens: Int
        let cacheReadTokens: Int
        let contextLimit: Int
        let turnCount: Int

        var contextUsed: Int { inputTokens + cacheReadTokens }
        var percentage: Double {
            guard contextLimit > 0 else { return 0 }
            return Double(contextUsed) / Double(contextLimit) * 100
        }

        var shortModel: String {
            if model.contains("opus") { return "opus" }
            if model.contains("sonnet") { return "sonnet" }
            if model.contains("haiku") { return "haiku" }
            return model
        }

        var contextString: String {
            let usedStr = contextUsed >= 1_000_000 ? "\(contextUsed / 1_000_000)M" : "\(contextUsed / 1000)k"
            let limitStr = contextLimit >= 1_000_000 ? "\(contextLimit / 1_000_000)M" : "\(contextLimit / 1000)k"
            return "\(usedStr)/\(limitStr) (\(Int(percentage))%)"
        }
    }

    struct SessionInfo {
        let sessionId: String
        let modificationDate: Date
        let firstUserMessage: String
    }

    /// Lists all Claude sessions for a project, sorted by most recent first.
    func listSessions(forProjectPath projectPath: String) -> [SessionInfo] {
        let encoded = projectPath.replacingOccurrences(of: "/", with: "-")
        let dir = NSHomeDirectory() + "/.claude/projects/\(encoded)"
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var results: [SessionInfo] = []

        for file in files where file.hasSuffix(".jsonl") {
            let sessionId = String(file.dropLast(6))
            let filePath = dir + "/" + file

            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }

            var firstMessage = ""

            if let fh = FileHandle(forReadingAtPath: filePath) {
                let headData = fh.readData(ofLength: 8192)
                try? fh.close()

                if let headStr = String(data: headData, encoding: .utf8) {
                    let lines = headStr.components(separatedBy: "\n")
                    for line in lines where !line.isEmpty {
                        guard let ld = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { continue }

                        let type = json["type"] as? String ?? ""
                        if type == "user" && firstMessage.isEmpty {
                            if let msg = json["message"] as? [String: Any] {
                                if let content = msg["content"] as? String {
                                    firstMessage = content
                                } else if let contentArr = msg["content"] as? [[String: Any]] {
                                    firstMessage = contentArr.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
                                }
                            }
                            break
                        }
                    }
                }
            }

            firstMessage = firstMessage.components(separatedBy: "\n").first ?? ""
            firstMessage = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)

            results.append(SessionInfo(
                sessionId: sessionId,
                modificationDate: modDate,
                firstUserMessage: firstMessage
            ))
        }

        results.sort { $0.modificationDate > $1.modificationDate }
        return results
    }

    /// Get context usage for a session by reading its JSONL file.
    func getUsage(sessionId: String, projectPath: String) -> ContextUsage? {
        let encoded = projectPath.replacingOccurrences(of: "/", with: "-")
        let jsonlPath = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionId).jsonl"

        guard FileManager.default.fileExists(atPath: jsonlPath) else { return nil }

        var lastInput = 0
        var lastCacheRead = 0
        var model = ""
        var turnCount = 0

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonlPath)) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")

        // Forward pass: count user turns
        for line in lines {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""
            if type == "user" { turnCount += 1 }
        }

        // Reverse pass: find last usage
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let msg = json["message"] as? [String: Any], let usage = msg["usage"] as? [String: Any] {
                lastInput = usage["input_tokens"] as? Int ?? 0
                lastCacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                if lastInput + lastCacheRead == 0 { continue }
                model = msg["model"] as? String ?? model
                break
            }

            if let msg = json["message"] as? [String: Any],
               let inner = msg["message"] as? [String: Any],
               let usage = inner["usage"] as? [String: Any] {
                lastInput = usage["input_tokens"] as? Int ?? 0
                lastCacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                if lastInput + lastCacheRead == 0 { continue }
                model = inner["model"] as? String ?? model
                break
            }
        }

        guard !model.isEmpty || lastInput > 0 || lastCacheRead > 0 else { return nil }

        let limit = contextLimits[model] ?? defaultLimit

        return ContextUsage(
            model: model,
            inputTokens: lastInput,
            cacheReadTokens: lastCacheRead,
            contextLimit: limit,
            turnCount: turnCount
        )
    }
}
