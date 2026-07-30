import Foundation

/// Lifecycle of a follow-up captured from a call.
enum FollowUpStatus: String, Codable, Sendable {
    case suggested   // detected on a call, waiting for confirmation in the review
    case scheduled   // confirmed by the user; a reminder is set for `dueAt`
    case done        // the user marked it handled
    case dismissed   // the user dismissed it
}

/// A time-referenced thing to revisit ("tomorrow we check the JTM script IDs").
/// Surfaces in the post-call review for confirmation; once confirmed, a local
/// notification fires at `dueAt` to bring it back.
struct FollowUp: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var callID: UUID?
    var title: String
    var quote: String?
    var dueAt: Date
    var createdAt = Date()
    var status: FollowUpStatus = .suggested

    var isOverdue: Bool { status == .scheduled && dueAt < Date() }
}

/// Parses follow-ups out of the post-call consolidation response (the LLM
/// extraction itself rides along in MemoryConsolidator's single request —
/// a dedicated pass used to re-send the whole transcript a second time).
/// Relative times were resolved by the model against the call's start time,
/// which the consolidator passes in the prompt.
enum FollowUpExtractor {

    static func parse(_ arguments: JSONValue, callID: UUID, callStart: Date) -> [FollowUp] {
        var out: [FollowUp] = []
        for item in arguments["followups"]?.arrayValue ?? [] {
            guard let title = item["title"]?.stringValue, !title.isEmpty,
                  let dueStr = item["due"]?.stringValue,
                  let due = parseDate(dueStr) else { continue }
            // Keep only genuinely future items (small grace for clock skew).
            guard due > callStart.addingTimeInterval(-300) else { continue }
            let quote = item["quote"]?.stringValue.map { String($0.prefix(300)) }
            out.append(FollowUp(callID: callID, title: String(title.prefix(200)),
                                quote: quote, dueAt: due, status: .suggested))
        }
        return out
    }

    /// Accepts ISO datetime, ISO date, or "yyyy-MM-dd[ HH:mm]". A date without a
    /// time defaults to 9:00 local so vague "tomorrow" lands in the morning.
    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let isoDateTime = ISO8601DateFormatter()
        isoDateTime.formatOptions = [.withInternetDateTime]
        if let d = isoDateTime.date(from: trimmed) { return d }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: trimmed) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) {
                if fmt == "yyyy-MM-dd" {
                    return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
                }
                return d
            }
        }
        return nil
    }
}
