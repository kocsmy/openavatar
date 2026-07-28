import Foundation

/// Decides when to start and stop transcription automatically around calls,
/// from periodic mic-ownership ticks (Granola-style seamlessness: join a Zoom
/// call, notes just happen).
///
/// Rules encoded here:
/// - Auto-start only when ARMED. Manually stopping capture mid-call disarms,
///   so the app doesn't fight the user by restarting two ticks later; it
///   re-arms once the call has actually ended (no app holds the mic).
/// - Auto-stop only after the call signal has been gone for several
///   consecutive ticks — brief mic drops (device switch, reconnect) must not
///   end the session. This applies to auto-started sessions always, and to
///   manually started ones once a call has actually been OBSERVED during the
///   session (regression: a 94-minute "call" that was 20 minutes of meeting
///   and 74 minutes of forgotten recording). A manual session in which no
///   call ever appears (dictation, testing) is never auto-stopped.
struct AutoSessionPolicy {
    /// Consecutive call-less ticks before a session ends
    /// (with 5s ticks: ~15s of silence-from-the-mic-owner).
    static let ticksToStop = 3

    private(set) var armed = true
    private(set) var missedTicks = 0
    /// A call app held the mic at some point during the CURRENT session —
    /// what makes a manually started session eligible for auto-stop.
    private(set) var callSeenThisSession = false

    enum Verdict: Equatable {
        case none, start, stop
    }

    /// Call when a listening session begins (manual or auto), so call
    /// sightings from the previous session can't carry over.
    mutating func sessionStarted() {
        callSeenThisSession = false
        missedTicks = 0
    }

    /// One detection tick. `callActive` = some app currently holds the mic.
    mutating func tick(enabled: Bool, isListening: Bool, autoStarted: Bool,
                       callActive: Bool) -> Verdict {
        guard enabled else {
            // Feature off: keep state neutral so enabling it later starts fresh.
            armed = true
            missedTicks = 0
            callSeenThisSession = false
            return .none
        }
        if isListening {
            if callActive {
                callSeenThisSession = true
                missedTicks = 0
                return .none
            }
            // No call in sight. Only sessions that belong to a call may end:
            // auto-started ones by definition, manual ones once one was seen.
            guard autoStarted || callSeenThisSession else { return .none }
            missedTicks += 1
            if missedTicks >= Self.ticksToStop {
                missedTicks = 0
                return .stop
            }
            return .none
        } else {
            missedTicks = 0
            callSeenThisSession = false
            if !callActive {
                armed = true   // call is over — future calls may auto-start again
                return .none
            }
            return armed ? .start : .none
        }
    }

    /// The user stopped capture themselves. If the call is still going,
    /// disarm — restarting against their explicit wish is the one
    /// unforgivable behavior here.
    mutating func userStopped(callStillActive: Bool) {
        armed = !callStillActive
        missedTicks = 0
        callSeenThisSession = false
    }
}
