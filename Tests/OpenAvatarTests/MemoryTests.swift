import XCTest
@testable import OpenAvatar

/// Improvement #1 — the compounding memory / proactive layer.
final class MemoryTests: XCTestCase {
    private var store: ContextStore!

    override func setUpWithError() throws {
        store = try ContextStore(inMemory: true)
    }

    func testFactLifecycle() throws {
        let fact = MemoryFact(category: .commitment,
                              content: "Promised Anna the pricing doc by Friday",
                              salience: 3)
        try store.insertFact(fact)

        var active = try store.activeFacts()
        XCTAssertEqual(active.count, 1)

        try store.reinforceFact(id: fact.id, newContent: "Promised Anna the pricing doc by THIS Friday")
        active = try store.activeFacts()
        XCTAssertEqual(active[0].salience, 3.5, accuracy: 0.01)
        XCTAssertTrue(active[0].content.contains("THIS Friday"))

        try store.retireFact(id: fact.id)
        XCTAssertTrue(try store.activeFacts().isEmpty)
    }

    func testBriefingGroupsByCategoryAndRespectsBudget() throws {
        try store.insertFact(MemoryFact(category: .identity, content: "Engineering lead at Initech", salience: 5))
        try store.insertFact(MemoryFact(category: .preference, content: "Prefers Linear tickets over GitHub issues", salience: 4))
        try store.insertDigest(callID: UUID(), digest: "Discussed Q3 roadmap")

        let briefing = store.memoryBriefing(maxChars: 2500)
        XCTAssertTrue(briefing.contains("Identity:"))
        XCTAssertTrue(briefing.contains("Engineering lead at Initech"))
        XCTAssertTrue(briefing.contains("Recent calls:"))

        let tiny = store.memoryBriefing(maxChars: 40)
        XCTAssertLessThanOrEqual(tiny.count, 41)
    }

    func testPruneRetiresOverflow() throws {
        for i in 0..<20 {
            try store.insertFact(MemoryFact(category: .pattern, content: "fact \(i)",
                                            salience: Double(i % 5) + 1))
        }
        try store.pruneMemory(maxActiveFacts: 10)
        XCTAssertEqual(try store.activeFacts().count, 10)
    }

    func testConsolidatorAppliesOperations() async throws {
        let existing = MemoryFact(category: .project, content: "Working on OpenAvatar", salience: 2)
        try store.insertFact(existing)
        let callID = UUID()

        let consolidator = MemoryConsolidator(router: LLMRouter(store: nil), store: store)
        let arguments = try JSONValue.parse("""
        {"digest": "Planned the launch.",
         "facts": [
            {"op": "add", "category": "commitment", "content": "Ship v1 by end of month", "salience": 4},
            {"op": "reinforce", "id": "\(existing.id.uuidString.prefix(8))"},
            {"op": "retire", "id": "ffffffff"}
         ]}
        """)
        let outcome = try await consolidator.apply(arguments, callID: callID,
                                                   existing: [existing])
        XCTAssertEqual(outcome.factsAdded, 1)
        XCTAssertEqual(outcome.factsReinforced, 1)
        XCTAssertEqual(outcome.factsRetired, 0) // unknown id ignored, not an error

        let commitments = try store.openCommitments()
        XCTAssertEqual(commitments.count, 1)
        XCTAssertTrue(commitments[0].content.contains("Ship v1"))
        XCTAssertEqual(try store.recentDigests(limit: 1).count, 1)
    }

    func testConsolidatorStoresMeetingNotesOnTheCall() async throws {
        let callID = try store.startCall(app: "Zoom")
        let consolidator = MemoryConsolidator(router: LLMRouter(store: nil), store: store)
        let arguments = try JSONValue.parse("""
        {"digest": "Reviewed June numbers.",
         "notes": "## June ARR\\n- Self-serve at $612k\\n- Churn 3.2%",
         "facts": []}
        """)
        let outcome = try await consolidator.apply(arguments, callID: callID, existing: [])
        XCTAssertTrue(outcome.notes.contains("June ARR"))

        let call = try XCTUnwrap(store.listCalls(limit: 5).first { $0.id == callID })
        XCTAssertEqual(call.notes, "## June ARR\n- Self-serve at $612k\n- Churn 3.2%")
    }

    func testMergedConsolidationParsesFollowUpsAndSpeakerNames() throws {
        // The single post-call request carries follow-ups and speaker guesses
        // alongside memory — one transcript send instead of three.
        let callStart = Date()
        let dueStr = ISO8601DateFormatter().string(
            from: callStart.addingTimeInterval(86_400))
        let callID = UUID()
        let arguments = try JSONValue.parse("""
        {"digest": "Planned the launch.",
         "facts": [],
         "followups": [
            {"title": "Check the JTM script IDs", "due": "\(dueStr)",
             "quote": "tomorrow we check the JTM script IDs"}
         ],
         "speaker_names": [
            {"speaker": "Speaker 3", "name": "Vasilis", "confidence": 0.9},
            {"speaker": "Speaker 5", "name": "unknown", "confidence": 0.9}
         ]}
        """)

        let followUps = FollowUpExtractor.parse(arguments, callID: callID, callStart: callStart)
        XCTAssertEqual(followUps.map(\.title), ["Check the JTM script IDs"])

        let guesses = MemoryConsolidator.speakerGuesses(from: arguments)
        XCTAssertEqual(guesses, [.init(label: "Speaker 3", name: "Vasilis")])
    }

    func testConsolidatorFactListIsCapped() throws {
        // Memory growth must not inflate every consolidation prompt.
        XCTAssertLessThanOrEqual(MemoryConsolidator.maxFactsInPrompt, 150)
        XCTAssertLessThanOrEqual(MemoryConsolidator.maxFactPromptChars, 9_000)
    }

    func testConsolidatorDemandsFullCoverage() {
        // Regression: 24k-char transcript cap dropped the first half of long
        // calls, and notes weren't required — long meetings came back with a
        // couple of thin bullets. The cap is a safety rail against runaway
        // sessions, NOT a meeting budget: 2-hour calls must pass through whole.
        XCTAssertGreaterThanOrEqual(MemoryConsolidator.maxTranscriptChars, 150_000)
        XCTAssertTrue(MemoryConsolidator.systemPrompt.contains("ENTIRE transcript"))
        XCTAssertTrue(MemoryConsolidator.systemPrompt.contains("## Next steps"))
        let required = MemoryConsolidator.updateMemoryTool.parameters["required"]?
            .arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(required.contains("notes"))
    }

    func testDeleteCallRemovesEverything() throws {
        let callID = try store.startCall(app: "Zoom")
        try store.insert([TranscriptSegment(text: "hello there", t0: 0, t1: 1,
                                            source: .mic, confidence: 0.9)],
                         callID: callID)
        try store.insert(Decision(callID: callID, quote: "I'll send it",
                                  intent: .sendEmail, summary: "Send the doc",
                                  assigneeHint: nil, confidence: 0.9,
                                  addressedToAssistant: false, source: .mic))
        try store.insertFollowUp(FollowUp(callID: callID, title: "Check tomorrow",
                                          quote: nil, dueAt: Date().addingTimeInterval(86_400)))
        try store.insertDigest(callID: callID, digest: "A call happened.")

        try store.deleteCall(callID)

        XCTAssertNil(try store.listCalls(limit: 50).first { $0.id == callID })
        XCTAssertTrue(try store.allSegments(callID: callID).isEmpty)
        XCTAssertTrue(try store.decisions(callID: callID).isEmpty)
        XCTAssertTrue(try store.followUps(callID: callID).isEmpty)
    }

    func testFactMatchByIDPrefix() {
        let fact = MemoryFact(category: .person, content: "Anna runs design", salience: 2)
        XCTAssertNotNil(MemoryConsolidator.match(String(fact.id.uuidString.prefix(8)), in: [fact]))
        XCTAssertNil(MemoryConsolidator.match("zzzzzzzz", in: [fact]))
        XCTAssertNil(MemoryConsolidator.match(nil, in: [fact]))
    }

    func testProactiveSuggestionParsingAndDecisionConversion() throws {
        let arguments = try JSONValue.parse("""
        {"suggestions": [
            {"title": "Send Anna the pricing doc",
             "rationale": "You promised it by Friday; it's Thursday.",
             "intent": "send_email",
             "action_summary": "Email Anna the pricing doc"}
        ]}
        """)
        let suggestions = ProactiveEngine.parse(arguments)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].intent, .sendEmail)

        let decision = suggestions[0].asDecision()
        XCTAssertEqual(decision.intent, .sendEmail)
        XCTAssertEqual(decision.summary, "Email Anna the pricing doc")
        XCTAssertFalse(decision.addressedToAssistant)
        XCTAssertEqual(decision.confidence, 1.0)
    }
}
