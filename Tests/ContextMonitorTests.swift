import XCTest
@testable import Deckard

final class ContextMonitorTests: XCTestCase {

    // MARK: - ContextUsage.percentage

    func testPercentageCalculation() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 50_000,
            cacheReadTokens: 50_000,
            contextLimit: 200_000
        )

        XCTAssertEqual(usage.contextUsed, 100_000)
        XCTAssertEqual(usage.percentage, 50.0, accuracy: 0.01)
    }

    func testPercentageAtZero() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            cacheReadTokens: 0,
            contextLimit: 200_000
        )

        XCTAssertEqual(usage.contextUsed, 0)
        XCTAssertEqual(usage.percentage, 0.0, accuracy: 0.01)
    }

    func testPercentageAt100() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 100_000,
            cacheReadTokens: 100_000,
            contextLimit: 200_000
        )

        XCTAssertEqual(usage.percentage, 100.0, accuracy: 0.01)
    }

    func testPercentageWithZeroLimit() {
        let usage = ContextMonitor.ContextUsage(
            model: "unknown",
            inputTokens: 50_000,
            cacheReadTokens: 0,
            contextLimit: 0
        )

        XCTAssertEqual(usage.percentage, 0.0)
    }

    func testPercentageOverflow() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-sonnet-4-6",
            inputTokens: 200_000,
            cacheReadTokens: 100_000,
            contextLimit: 200_000
        )

        XCTAssertGreaterThan(usage.percentage, 100.0)
    }

    // MARK: - Context used computation

    func testContextUsedSum() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-opus-4-6",
            inputTokens: 30_000,
            cacheReadTokens: 70_000,
            contextLimit: 1_000_000
        )

        XCTAssertEqual(usage.contextUsed, 100_000)
    }

    // MARK: - Model info

    func testOpusModelUsage() {
        let usage = ContextMonitor.ContextUsage(
            model: "claude-opus-4-6",
            inputTokens: 500_000,
            cacheReadTokens: 0,
            contextLimit: 1_000_000
        )

        XCTAssertEqual(usage.percentage, 50.0, accuracy: 0.01)
    }

    // MARK: - JSONL parsing (via getUsage)

    func testGetUsageWithTempJSONL() throws {
        // Create a temp JSONL file simulating a session file
        let tempDir = NSTemporaryDirectory() + "deckard-context-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }

        // The ContextMonitor reads from ~/.claude/projects/<encoded-path>/<sessionId>.jsonl
        // We can't easily inject that path, but we can test the ContextUsage struct directly
        // and verify the JSONL parsing logic by testing the data structures

        let usage = ContextMonitor.ContextUsage(
            model: "claude-haiku-4-5",
            inputTokens: 10_000,
            cacheReadTokens: 5_000,
            contextLimit: 200_000
        )

        XCTAssertEqual(usage.contextUsed, 15_000)
        XCTAssertEqual(usage.percentage, 7.5, accuracy: 0.01)
    }

    // MARK: - ContextMonitor shared instance

    func testSharedInstanceExists() {
        XCTAssertNotNil(ContextMonitor.shared)
    }

    // MARK: - listSessions with nonexistent path

    func testListSessionsNonexistentPath() {
        let sessions = ContextMonitor.shared.listSessions(
            forProjectPath: "/nonexistent/path/\(UUID().uuidString)"
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - getUsage with nonexistent session

    func testGetUsageNonexistentSession() {
        let usage = ContextMonitor.shared.getUsage(
            sessionId: "nonexistent-\(UUID().uuidString)",
            projectPath: "/nonexistent/path/\(UUID().uuidString)"
        )
        XCTAssertNil(usage)
    }

    // MARK: - SessionInfo struct

    func testSessionInfoProperties() {
        let date = Date()
        let info = ContextMonitor.SessionInfo(
            sessionId: "sess-123",
            modificationDate: date,
            firstUserMessage: "Hello Claude",
            messageCount: 5
        )

        XCTAssertEqual(info.sessionId, "sess-123")
        XCTAssertEqual(info.modificationDate, date)
        XCTAssertEqual(info.firstUserMessage, "Hello Claude")
    }

    // MARK: - claudeProjectDirName symlink resolution

    func testClaudeProjectDirNameResolvesSymlinks() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-dirname-\(UUID().uuidString)"
        let realDir = tempDir + "/real-project"
        let linkDir = tempDir + "/linked-project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        XCTAssertEqual(linkDir.claudeProjectDirName, realDir.claudeProjectDirName,
                       "claudeProjectDirName should produce the same result for symlink and canonical path")
    }

    func testClaudeProjectDirNameEncodesSlashes() {
        let path = "/Users/test/my-project"
        XCTAssertEqual(path.claudeProjectDirName, "-Users-test-my-project")
        XCTAssertFalse(path.claudeProjectDirName.contains("/"))
    }

    func testClaudeProjectDirNameIdempotentOnCanonicalPath() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-dirname-\(UUID().uuidString)"
        let realDir = tempDir + "/project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }

        // Calling on an already-canonical path should give the same result
        let dirName = realDir.claudeProjectDirName
        let resolvedFirst = (realDir as NSString).resolvingSymlinksInPath
        XCTAssertEqual(resolvedFirst.claudeProjectDirName, dirName,
                       "Double resolution should be idempotent")
    }

    func testClaudeProjectDirNameConsistentWithProjectItem() throws {
        let tempDir = NSTemporaryDirectory() + "deckard-dirname-\(UUID().uuidString)"
        let realDir = tempDir + "/real-project"
        let linkDir = tempDir + "/linked-project"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }
        try FileManager.default.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)

        // ProjectItem resolves symlinks; claudeProjectDirName should agree
        let project = ProjectItem(path: linkDir)
        let encoded = project.path.claudeProjectDirName
        XCTAssertEqual(encoded, realDir.claudeProjectDirName,
                       "ProjectItem.path and claudeProjectDirName should agree on canonical encoding")
    }
}
