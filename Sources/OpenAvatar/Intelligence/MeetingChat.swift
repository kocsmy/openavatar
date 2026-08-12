import Foundation

/// Questions answered from what was actually said.
///
/// Two shapes, both grounded: `ask` puts ONE meeting in context and answers
/// about it; `search` works across the library. Neither invents — the system
/// prompt makes "the calls don't say" a valid answer, because a confident
/// wrong answer about a meeting the user attended is worse than no answer.
///
/// Context is the constraint. A year of calls is far past any window, so
/// `search` is two-stage: a compact index (date, title, digest) picks the
/// handful of meetings worth reading, then only those are read in full. The
/// index costs a few thousand characters no matter how many meetings exist.
@MainActor
final class MeetingChat {

    /// Per-meeting Q&A: enough room for a long call's transcript.
    static let maxTranscriptChars = 40_000
    /// Per-meeting budget in the second search stage, where several compete.
    static let maxSearchTranscriptChars = 14_000
    /// The whole index must stay small — it's sent on every search.
    static let maxIndexChars = 12_000
    /// Meetings the picker may pull in for a full read.
    static let maxShortlist = 4
    /// Prior turns carried forward; older ones drop off.
    static let maxHistoryTurns = 6

    struct Turn: Sendable, Equatable {
        let role: ChatRole
        let content: String
    }

    struct Answer: Sendable, Equatable {
        var text: String
        /// Meetings the answer drew on, for citation chips in the UI.
        var callIDs: [UUID] = []
    }

    private let router: LLMRouter
    private let store: ContextStore

    init(router: LLMRouter, store: ContextStore) {
        self.router = router
        self.store = store
    }

    // MARK: One meeting

    func ask(callID: UUID, question: String, history: [Turn] = []) async throws -> Answer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Answer(text: "") }
        guard let call = try store.listCalls().first(where: { $0.id == callID }) else {
            throw AppError.parsing("Unknown meeting")
        }
        let context = Self.meetingContext(call: call,
                                          segments: (try? store.segments(callID: callID)) ?? [],
                                          decisions: (try? store.decisions(callID: callID)) ?? [],
                                          limit: Self.maxTranscriptChars)
        let request = LLMRequest(
            model: "",
            system: Self.systemPrompt,
            messages: Self.messages(history: history, question: """
                \(context)

                Question about this meeting: \(trimmed)
                """),
            maxTokens: 1500,
            // The meeting is the same on every follow-up; only the question
            // changes, so the transcript should be read from cache.
            cachePrefix: true)
        let response = try await router.complete(task: .summary, request)
        return Answer(text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      callIDs: [callID])
    }

    // MARK: The whole library

    func search(query: String, history: [Turn] = []) async throws -> Answer {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Answer(text: "") }
        let calls = try store.listCalls()
        guard !calls.isEmpty else {
            return Answer(text: "There are no recorded meetings yet.")
        }

        let index = Self.index(of: calls, limit: Self.maxIndexChars)
        let shortlist = try await pick(from: calls, index: index, query: trimmed)

        // Nothing looked relevant: answer from the index rather than pretending
        // to have read something.
        guard !shortlist.isEmpty else {
            let request = LLMRequest(
                model: "", system: Self.systemPrompt,
                messages: Self.messages(history: history, question: """
                    Meetings on record (date, title, digest):
                    \(index)

                    Question: \(trimmed)

                    None of these looked like a close match. Answer from the \
                    digests above if you can, and say plainly that you didn't \
                    read any full transcript.
                    """),
                maxTokens: 1200)
            return Answer(text: try await router.complete(task: .summary, request).text
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var bodies: [String] = []
        for call in shortlist {
            bodies.append(Self.meetingContext(
                call: call,
                segments: (try? store.segments(callID: call.id)) ?? [],
                decisions: (try? store.decisions(callID: call.id)) ?? [],
                limit: Self.maxSearchTranscriptChars))
        }
        let request = LLMRequest(
            model: "", system: Self.systemPrompt,
            messages: Self.messages(history: history, question: """
                \(bodies.joined(separator: "\n\n———\n\n"))

                Question: \(trimmed)

                Answer from these meetings. Name the meeting and its date \
                whenever you state something, so it can be checked.
                """),
            maxTokens: 1600)
        let response = try await router.complete(task: .summary, request)
        return Answer(text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      callIDs: shortlist.map(\.id))
    }

    /// Stage one: which meetings are worth reading in full. Returns them in
    /// the model's order of relevance.
    private func pick(from calls: [ContextStore.CallRecord],
                      index: String, query: String) async throws -> [ContextStore.CallRecord] {
        let request = LLMRequest(
            model: "",
            system: """
                You choose which meetings to read. Reply with ONLY the \
                reference numbers of the meetings worth reading for the \
                question, most relevant first, comma-separated (e.g. "3, 7"). \
                At most \(Self.maxShortlist). Reply with "none" if nothing \
                looks relevant. No other text.
                """,
            messages: [ChatMessage(role: .user, content: """
                Meetings on record:
                \(index)

                Question: \(query)
                """)],
            maxTokens: 60)
        let reply = try await router.complete(task: .summary, request).text
        return Self.resolve(reply, against: calls)
    }

    // MARK: Pure helpers (pinned by tests)

    /// Parses the picker's reply into meetings. Tolerant on purpose — models
    /// answer "2, 5", "#2 and #5", or "Meetings 2, 5" and all of them mean
    /// the same thing.
    static func resolve(_ reply: String, against calls: [ContextStore.CallRecord]) -> [ContextStore.CallRecord] {
        guard !reply.lowercased().contains("none") else { return [] }
        var seen = Set<Int>()
        var out: [ContextStore.CallRecord] = []
        let characters = Array(reply)
        var i = 0
        while i < characters.count {
            guard characters[i].isNumber else { i += 1; continue }
            var end = i
            while end < characters.count, characters[end].isNumber { end += 1 }
            // Splitting on non-digits would strip the sign and turn "-1" into
            // meeting #1 — a nonsense answer quietly reading a real transcript.
            let negated = i > 0 && characters[i - 1] == "-"
            let digits = Int(String(characters[i..<end]))
            i = end
            guard !negated, let number = digits, number >= 1, number <= calls.count,
                  !seen.contains(number) else { continue }
            seen.insert(number)
            out.append(calls[number - 1])
            if out.count == maxShortlist { break }
        }
        return out
    }

    /// The compact catalogue: one line per meeting, newest first, numbered so
    /// the picker can answer with numbers instead of echoing UUIDs.
    static func index(of calls: [ContextStore.CallRecord], limit: Int) -> String {
        var out = ""
        for (offset, call) in calls.enumerated() {
            let digest = (call.summary ?? "").replacingOccurrences(of: "\n", with: " ")
            var line = "\(offset + 1). \(Self.day.string(from: call.startedAt))"
            line += " — \(call.displayTitle)"
            if !digest.isEmpty { line += ": \(digest.prefix(220))" }
            line += "\n"
            // Truncate the catalogue rather than the question: the oldest
            // meetings are the ones most likely to be irrelevant.
            guard out.count + line.count <= limit else { break }
            out += line
        }
        return out.isEmpty ? "(none)" : out
    }

    /// One meeting rendered for the model: what it was, what the user wrote,
    /// what was decided, and what was said.
    static func meetingContext(call: ContextStore.CallRecord, segments: [TranscriptSegment],
                               decisions: [Decision], limit: Int) -> String {
        var out = "Meeting: \(call.displayTitle)\nDate: \(Self.stamp.string(from: call.startedAt))\n"
        if let app = call.app, !app.isEmpty { out += "Platform: \(app)\n" }
        if let notes = call.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            out += "\nThe user's own notes:\n\(notes)\n"
        }
        if let summary = call.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            out += "\nSummary:\n\(summary)\n"
        }
        let live = decisions.filter { $0.status != .dismissed }
        if !live.isEmpty {
            out += "\nAction items:\n"
            for decision in live { out += "- \(decision.summary)\n" }
        }
        let transcript = segments.map { "[\($0.speakerLabel)] \($0.text)" }.joined(separator: "\n")
        if !transcript.isEmpty {
            // Keep the tail: the end of a call carries the decisions.
            var capped = String(transcript.suffix(limit))
            if capped.count < transcript.count {
                capped = "(earlier part omitted)\n" + capped
            }
            out += "\nTranscript:\n\(capped)\n"
        }
        return out
    }

    private static func messages(history: [Turn], question: String) -> [ChatMessage] {
        var messages = history.suffix(maxHistoryTurns).map {
            ChatMessage(role: $0.role, content: $0.content)
        }
        messages.append(ChatMessage(role: .user, content: question))
        return messages
    }

    static let systemPrompt = """
        You answer questions about the user's own recorded meetings, from the \
        transcripts and notes provided. Ground every claim in what is actually \
        there. If the material doesn't answer the question, say so plainly \
        instead of guessing — the user was in these meetings and will catch a \
        confident invention immediately. Quote a short phrase when a quote \
        settles it. Be brief: a couple of sentences, or a short list when the \
        answer really is a list. No preamble, no restating the question.
        """

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
