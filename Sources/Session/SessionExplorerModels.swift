import Foundation

/// A Claude Code session on disk, enriched with parsed metadata.
struct ExplorerSessionInfo {
    let sessionId: String
    let filePath: URL
    let modificationDate: Date
    var messageCount: Int
    let firstUserMessage: String
    var savedName: String?
    var summary: String?
    var isBookmarked: Bool
}

/// A single user turn within a session timeline.
struct TimelineEntry {
    let index: Int
    let promptId: String
    let message: String
    let timestamp: Date?
    var actionSummary: String?
}
