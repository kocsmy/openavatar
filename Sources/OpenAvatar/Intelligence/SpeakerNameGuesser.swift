import Foundation

/// Filters the speaker-name guesses returned by the post-call consolidation
/// pass (the LLM work itself rides along in MemoryConsolidator's single
/// request — a dedicated pass used to re-send the whole transcript a third
/// time). Guesses come from conversational evidence — self-introductions
/// ("hi, this is Alexa"), direct address ("thanks, Vasilis"), or a host
/// announcing who joined — and are applied only to profiles the user hasn't
/// named, so a manual name always wins; everything stays user-editable
/// (rename/Clear) in the per-call speaker list.
enum SpeakerNameGuesser {

    /// Guesses below this confidence are ignored — a wrong auto-name is worse
    /// than "Speaker N".
    static let minConfidence = 0.7

    struct AppliedGuess: Sendable, Equatable {
        let profileID: UUID
        let name: String
    }

    struct Guess: Equatable {
        let label: String
        let name: String
    }

    /// Keeps only confident, plausible name guesses. Pure so tests can pin the
    /// filtering exactly.
    ///
    /// `roster` is the meeting's invitee list. When we have one, a guess must
    /// name somebody on it — that turns naming from "invent a name from the
    /// transcript" into "match a voice to a known person", which is the change
    /// that stops a name merely *mentioned* in conversation ("happy birthday
    /// to your son, Conrad") from becoming a speaker who was never present.
    static func parse(_ arguments: JSONValue, roster: [String] = []) -> [Guess] {
        var seen: Set<String> = []
        var out: [Guess] = []
        for item in arguments["names"]?.arrayValue ?? [] {
            guard let label = item["speaker"]?.stringValue,
                  let raw = item["name"]?.stringValue else { continue }
            let confidence = item["confidence"]?.numberValue ?? 0
            guard confidence >= minConfidence else { continue }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = canonical(name, in: roster) else { continue }
            // Plausibility: short human-name shape, not a sentence or a role.
            guard !name.isEmpty, name.count <= 40,
                  name.rangeOfCharacter(from: .newlines) == nil,
                  name.split(separator: " ").count <= 3,
                  name.lowercased() != "unknown", name.lowercased() != "speaker" else { continue }
            // One name per speaker; one speaker per name (avoid collapsing).
            guard !seen.contains(label), !out.contains(where: { $0.name == name }) else { continue }
            seen.insert(label)
            out.append(Guess(label: label, name: name))
        }
        return out
    }

    /// The roster's own spelling of a guessed name, or the guess unchanged
    /// when there is no roster to check against. Nil rejects the guess.
    static func canonical(_ name: String, in roster: [String]) -> String? {
        guard !roster.isEmpty else { return name }
        let needle = name.lowercased()
        if let exact = roster.first(where: { $0.lowercased() == needle }) { return exact }
        // People are called by their first name on a call and invited by
        // their full one, so "Vasilis" should find "Vasilis Andreou" — but
        // only when exactly one invitee can be meant.
        let partial = roster.filter {
            $0.lowercased().split(separator: " ").contains(Substring(needle))
        }
        return partial.count == 1 ? partial[0] : nil
    }
}
