import Foundation

/// Recent-message window for memory derivation: non-empty lines, chronological order, capped count and optional age from the newest message.
enum MemoryTranscriptWindow {
    static let defaultMaxMessageCount = 30
    static let defaultMaxAge: TimeInterval = 14 * 24 * 3600

    static func recentMessagesForDerivation(
        _ messages: [ChatMessage],
        maxCount: Int = defaultMaxMessageCount,
        maxAge: TimeInterval? = defaultMaxAge
    ) -> [ChatMessage] {
        let nonEmpty = messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sorted = nonEmpty.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        let timeFiltered: [ChatMessage]
        if let maxAge, let newest = sorted.last?.date {
            let cutoff = newest.addingTimeInterval(-maxAge)
            timeFiltered = sorted.filter { $0.date >= cutoff }
        } else {
            timeFiltered = sorted
        }
        return Array(timeFiltered.suffix(maxCount))
    }
}
