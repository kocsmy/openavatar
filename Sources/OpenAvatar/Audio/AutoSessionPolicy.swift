import Foundation

/// Decides when to start and stop transcription automatically around calls,
/// from periodic mic-ownership ticks (Granola-style seamlessness: join a Zoom
/// call, notes just happen).
///
/// Rules encoded here:
/// - Auto-start only when ARMED. Manually stopping capture mid-call disarms,
///   so the app doesn't fight the user by restarting two ticks later; it
///   re-arms once the call has actually ended (no app holds the mic).
/// - Auto-stop only sessions that were auto-started, and only after the call
///   signal has been gone for several consecutive ticks — brief mic drops
///   (device switch, reconnect) must not end the session. Manually started
///   sessions are never auto-stopped: they may be dictation with no call app.
struct AutoSessionPolicy {
    /// Consecutive call-less ticks before an auto-started session ends
    /// (with 5s ticks: ~15s of silence-from-the-mic-owner).
    static let ticksToStop = 3

    private(set) var armed = true
    private(set) var missedTicks = 0

    enum Verdict: Equatable {
        case none, start, stop
    }

    /// One detection tick. `callActive` = some app currently holds the mic.
    mutating func tick(enabled: Bool, isListening: Bool, autoStarted: Bool,
                       callActive: Bool) -> Verdict {
        guard enabled else {
            // Feature off: keep state neutral so enabling it later starts fresh.
            armed = true
            missedTicks = 0
            return .none
        }
        if isListening {
            guard autoStarted else { return .none }
            if callActive {
                missedTicks = 0
                return .none
            }
            missedTicks += 1
            if missedTicks >= Self.ticksToStop {
                missedTicks = 0
                return .stop
            }
            return .none
        } else {
            missedTicks = 0
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
    }
}
