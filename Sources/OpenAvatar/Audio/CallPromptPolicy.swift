import Foundation

/// When to show the floating "Take notes?" prompt (Granola-style): an app is
/// holding the microphone, we are not recording, and auto-start is not about
/// to handle it anyway. Pure so the matrix is unit-tested.
enum CallPromptPolicy {
    /// - strongSignal: known call app, or browser during a calendar meeting —
    ///   the cases auto-start acts on by itself when enabled.
    /// - dismissed: the user closed the prompt for the ongoing call; it must
    ///   not nag again until that call ends.
    static func shouldPrompt(isListening: Bool, callDetected: Bool, strongSignal: Bool,
                             autoStartEnabled: Bool, dismissed: Bool) -> Bool {
        guard !isListening, callDetected, !dismissed else { return false }
        // Strong signals are auto-start's job while it's on — prompting too
        // would double up (and one tick later the session starts anyway).
        if autoStartEnabled && strongSignal { return false }
        return true
    }
}
