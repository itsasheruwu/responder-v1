import AppKit
import Foundation

actor MessagesSender: MessageSenderProtocol {
    func send(text: String, to conversation: ConversationRef) async throws {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            send "\(escaped)" to chat id "\(conversation.id)"
        end tell
        """

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw ResponderError.sendBlocked("Failed to create the AppleScript send request.")
        }

        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw ResponderError.sendBlocked("Messages rejected the send request: \(errorInfo)")
        }
    }
}
