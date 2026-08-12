/** Home surface bridge contract. Mirrors Sources/OpenAvatar/WebUI/Bridges/HomeBridge.swift. */

/** One upcoming calendar event, pre-formatted for the "Coming up" list. */
export interface HomeEvent {
  id: string;
  title: string;
  /** ISO-8601, or null for an event with no start time. */
  start: string | null;
  end: string | null;
  conferenceService: string | null;
  /** Everyone but the account owner, e.g. "Salim + 3 more"; null if nobody else is invited. */
  participantSummary: string | null;
  /** True while the event's [start, end] window contains "now", at snapshot time. */
  isNow: boolean;
}

export interface HomeSnapshot {
  isListening: boolean;
  autoStartOnCall: boolean;
  calendarEnabled: boolean;
  /** Next 7 days on the selected calendar — empty when calendar is off. */
  events: HomeEvent[];
}

export interface HomeAPI {
  "home.snapshot": [Record<string, never>, HomeSnapshot];
  /** Best-effort calendar refresh — mirrors the native view's onAppear. */
  "home.refresh": [Record<string, never>, Record<string, never>];
  "home.startListening": [Record<string, never>, Record<string, never>];
  "home.stopListening": [Record<string, never>, Record<string, never>];
  /** Opens the meeting's notes (the call window) — pre-write before the call starts. */
  "home.openEventNotes": [{ eventID: string }, Record<string, never>];
}
