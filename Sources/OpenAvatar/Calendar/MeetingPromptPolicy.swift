import Foundation

/// When to surface the pre-meeting prompt ("Web Engineering Sync starts in a
/// minute — join?"). Pure so tests can pin the exact window: from one minute
/// before the event's start until ten minutes after (late joiners still get
/// it), once per event, and never while a session is already recording.
enum MeetingPromptPolicy {
    /// Show this long before the event starts.
    static let leadSeconds: TimeInterval = 60
    /// Keep offering this long after the start (joining late happens).
    static let graceSeconds: TimeInterval = 600

    static func shouldPrompt(eventStart: Date?, now: Date,
                             isListening: Bool, alreadyPrompted: Bool) -> Bool {
        guard let start = eventStart, !isListening, !alreadyPrompted else { return false }
        return now >= start.addingTimeInterval(-leadSeconds)
            && now <= start.addingTimeInterval(graceSeconds)
    }
}
