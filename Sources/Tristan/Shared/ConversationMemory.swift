import Foundation

/// What one finished mission left behind: the task, the actions taken, and how it ended.
struct Exchange: Codable, Equatable, Sendable {
    var task: String
    var actions: [String]
    var outcome: String
    var status: String
    var folder: String
}

/// A session's memory of its own missions. A mission that has finished stays in the session's context, so the next
/// task can say "now fix the test you just wrote". Every provider starts a run with no history of its own, so the
/// memory is rendered as a short briefing in front of the new task. A new session starts with an empty memory.
struct ConversationMemory: Codable, Equatable, Sendable {
    static let maxExchanges = 12
    static let fullDetail = 3
    static let maxActions = 10
    static let maxOutcome = 700
    static let maxBriefing = 6_000

    private(set) var exchanges: [Exchange] = []

    var isEmpty: Bool { exchanges.isEmpty }

    mutating func record(task: String, actions: [String], outcome: String, status: String, folder: String) {
        exchanges.append(Exchange(task: Self.clip(task, 400), actions: Array(actions.suffix(Self.maxActions)),
                                  outcome: Self.clip(outcome, Self.maxOutcome), status: status, folder: folder))
        if exchanges.count > Self.maxExchanges { exchanges.removeFirst(exchanges.count - Self.maxExchanges) }
    }

    mutating func clear() { exchanges = [] }

    /// The task with the briefing in front of it. Only missions from the same folder are included, because what was
    /// done in another project says nothing about this one. With nothing to remember the task goes through unchanged.
    func compose(task: String, folder: String) -> String {
        let relevant = exchanges.filter { $0.folder == folder }
        guard !relevant.isEmpty else { return task }
        var lines: [String] = []
        let recentStart = max(relevant.count - Self.fullDetail, 0)
        for (index, exchange) in relevant.enumerated() {
            let number = index + 1
            if index < recentStart {
                lines.append("\(number). [\(exchange.status)] \(Self.clip(exchange.task, 120)) → \(Self.clip(exchange.outcome, 120))")
            } else {
                lines.append("\(number). [\(exchange.status)] Task: \(exchange.task)")
                if !exchange.actions.isEmpty { lines.append("   Actions: " + exchange.actions.joined(separator: "; ")) }
                lines.append("   Result: \(exchange.outcome)")
            }
        }
        var body = lines.joined(separator: "\n")
        if body.count > Self.maxBriefing { body = "…" + body.suffix(Self.maxBriefing) }
        return """
        Context: you have already worked in this folder during this session. Earlier missions, oldest first:
        \(body)

        Treat that as what you and the user already did, and do not repeat it. Current task:
        \(task)
        """
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
