import Foundation

/// Processes hook events from Claude Code and updates tab state accordingly.
class HookHandler {
    weak var windowController: DeckardWindowController?

    func handle(_ message: ControlMessage, reply: @escaping (ControlResponse) -> Void) {
        switch message.command {

        // --- Hook events from Claude Code ---

        case "hook.session-start":
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .waitingForInput)
                windowController?.revealClaudeTab(surfaceId: surfaceId)
                // Capture the real session ID from Claude Code
                if let sessionId = message.sessionId {
                    windowController?.updateSessionId(forSurfaceId: surfaceId, sessionId: sessionId)
                }
            }
            reply(ControlResponse(ok: true))

        case "hook.stop":
            // Claude finished responding — waiting for user input
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .waitingForInput)
            }
            reply(ControlResponse(ok: true))

        case "hook.notification":
            if let surfaceId = message.surfaceId {
                let type = message.notificationType ?? ""
                if type.contains("permission") {
                    windowController?.updateBadge(forSurfaceId: surfaceId, state: .needsPermission)
                } else {
                    windowController?.updateBadge(forSurfaceId: surfaceId, state: .waitingForInput)
                }
            }
            reply(ControlResponse(ok: true))

        case "hook.user-prompt-submit":
            // User typed something — Claude is thinking
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .thinking)
            }
            reply(ControlResponse(ok: true))

        case "hook.pre-tool-use":
            // Tool starting — Claude is thinking/working
            if let surfaceId = message.surfaceId {
                windowController?.updateBadge(forSurfaceId: surfaceId, state: .thinking)
            }
            reply(ControlResponse(ok: true))

        // --- Query commands ---

        case "list-tabs":
            let tabs = windowController?.listTabInfo() ?? []
            reply(ControlResponse(ok: true, tabs: tabs))

        case "create-tab":
            if let dir = message.workingDirectory {
                windowController?.openProject(path: dir)
            }
            reply(ControlResponse(ok: true))

        case "rename-tab":
            if let tabId = message.tabId, let name = message.name {
                windowController?.renameTab(id: tabId, name: name)
            }
            reply(ControlResponse(ok: true))

        case "close-tab":
            if let tabId = message.tabId {
                windowController?.closeTabById(tabId)
            }
            reply(ControlResponse(ok: true))

        case "focus-tab":
            if let tabId = message.tabId {
                if let uuid = UUID(uuidString: tabId) {
                    windowController?.focusTabById(uuid)
                }
            }
            reply(ControlResponse(ok: true))

        case "ping":
            reply(ControlResponse(ok: true, message: "pong"))

        default:
            reply(ControlResponse(ok: false, error: "unknown command: \(message.command)"))
        }
    }

}
