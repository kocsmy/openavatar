/**
 * Onboarding surface bridge contract. Mirrors
 * Sources/OpenAvatar/WebUI/Bridges/OnboardingBridge.swift.
 *
 * Most of the wizard reads and writes through the settings bridge already —
 * `settings.set`, `secrets.save`, `routes.set`, `models.list`,
 * `transcription.*`, `integrations.checkAll`, `calendar.connect` — see
 * lib/types.ts. This file only adds what's genuinely new: the microphone TCC
 * prompt, the one-time admin-minutes baseline, resetting the trust matrix,
 * and marking onboarding complete.
 */
export interface OnboardingAPI {
  /** Fires the real macOS microphone prompt (once per install). */
  "onboarding.requestMicrophone": [Record<string, never>, { granted: boolean }];
  /** Deep-links System Settings → Privacy → Microphone, for a prior denial. */
  "onboarding.openMicrophoneSettings": [Record<string, never>, Record<string, never>];
  /** Feeds the metrics dashboard's "time saved" baseline. */
  "onboarding.setBaseline": [{ minutes: number }, Record<string, never>];
  /** TrustStep's "Reset to these defaults". */
  "onboarding.resetTrustDefaults": [Record<string, never>, Record<string, never>];
  /** Sets the same completion flag the native flow set; window.close follows. */
  "onboarding.finish": [Record<string, never>, Record<string, never>];
}
