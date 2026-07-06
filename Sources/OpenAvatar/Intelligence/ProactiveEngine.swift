import Foundation

/// A suggestion the assistant surfaces on its own initiative, derived from
/// open commitments and recent call digests. Proactivity never bypasses the
/// trust ladder: suggestions only become actions through the normal
/// prepare → preview → approve flow, always Ask-first.
struct ProactiveSuggestion: Identifiable, Sendable {
    let id = UUID()
    var title: String        // "You promised Anna the pricing doc by Friday"
    var rationale: String    // why now
    var intent: DecisionIntent
    var actionSummary: String // one-line action for the planner

    /// Converts to a synthetic decision that flows through the standard
    /// planning + approval pipeline.
    func asDecision() -> Decision {
        Decision(quote: rationale,
                 intent: intent,
                 summary: actionSummary,
                 assigneeHint: nil,
                 confidence: 1.0,
                 addressedToAssistant: false,
                 source: .mic)
    }
}

/// Improvement #1, proactive half: after consolidation (and on demand), asks
/// the cheap model whether anything in memory warrants acting now.
actor ProactiveEngine {
    private let router: LLMRouter
    private let store: ContextStore

    init(router: LLMRouter, store: ContextStore) {
        self.router = router
        self.store = store
    }

    func suggestions(maxCount: Int = 3) async throws -> [ProactiveSuggestion] {
        let commitments = (try? store.openCommitments()) ?? []
        let digests = (try? store.recentDigests(limit: 5)) ?? []
        guard !commitments.isEmpty || !digests.isEmpty else { return [] }

        let briefing = store.memoryBriefing(maxChars: 2000)
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short

        let request = LLMRequest(
            model: "",
            system: Self.systemPrompt,
            messages: [ChatMessage(role: .user, content: """
                Now: \(df.string(from: Date()))

                What you know about the user:
                \(briefing.isEmpty ? "(nothing yet)" : briefing)

                Open commitments:
                \(commitments.isEmpty ? "(none)" : commitments.map { "- \($0.content)" }.joined(separator: "\n"))

                Call suggest_actions once with 0–\(maxCount) suggestions.
                """)],
            tools: [Self.suggestActionsTool],
            toolChoice: .required,
            maxTokens: 1024)

        let response = try await router.complete(task: .summary, request)
        guard let call = response.toolCalls.first(where: { $0.name == "suggest_actions" }) else {
            return []
        }
        return Self.parse(call.arguments).prefix(maxCount).map { $0 }
    }

    static func parse(_ arguments: JSONValue) -> [ProactiveSuggestion] {
        (arguments["suggestions"]?.arrayValue ?? []).compactMap { item in
            guard let title = item["title"]?.stringValue,
                  let action = item["action_summary"]?.stringValue else { return nil }
            return ProactiveSuggestion(
                title: title,
                rationale: item["rationale"]?.stringValue ?? title,
                intent: DecisionIntent(rawValue: item["intent"]?.stringValue ?? "") ?? .other,
                actionSummary: action)
        }
    }

    static let systemPrompt = """
        You are a proactive but restrained personal assistant. Based only on the \
        user's memory and open commitments, suggest concrete actions worth doing \
        NOW (e.g. a commitment nearing its deadline with no sign of completion, \
        a follow-up nobody sent). Every suggestion must map to one executable \
        action: create_ticket, code_change, send_message, or send_email.

        Suggest nothing when nothing is clearly warranted — silence is better \
        than noise. Never suggest destructive actions like merging PRs.
        """

    static let suggestActionsTool = ToolSpec(
        name: "suggest_actions",
        description: "Propose proactive actions (possibly none).",
        parameters: .object([
            "type": "object",
            "properties": .object([
                "suggestions": .object([
                    "type": "array",
                    "items": .object([
                        "type": "object",
                        "properties": .object([
                            "title": .object(["type": "string", "description": "short user-facing headline"]),
                            "rationale": .object(["type": "string", "description": "why now, referencing the commitment"]),
                            "intent": .object(["type": "string",
                                               "enum": .array(["create_ticket", "code_change",
                                                               "send_message", "send_email"])]),
                            "action_summary": .object(["type": "string", "description": "one-line action for the planner"])
                        ]),
                        "required": .array(["title", "intent", "action_summary"])
                    ])
                ])
            ]),
            "required": .array(["suggestions"])
        ]))
}
