/** Call surface bridge contract. Mirrors Sources/OpenAvatar/WebUI/Bridges/CallBridge.swift. */

/**
 * Which face the window shows, mirroring CallNotesWindowView's own branching:
 * an upcoming meeting's notes pad, the live call, or (once stopped) a
 * lightweight "call ended" handoff — the full review lives in Meetings.
 */
export type CallWindowMode = "event" | "live" | "ended";

export interface CallPreviewEvent {
  id: string;
  title: string;
  start: string | null;
  end: string | null;
  conferenceService: string | null;
  /** "Salim + 3 more" — precomputed server-side (excludes the account owner). */
  participantSummary: string | null;
}

export interface CallEndedSummary {
  title: string;
  startedAt: string;
  endedAt: string | null;
  appName: string | null;
  /** Structured AI notes (resolvedNotes), when consolidation has written them. */
  notes: string | null;
  /** Legacy digest string for older calls without structured notes — ";"-joined. */
  summary: string | null;
  isConsolidating: boolean;
}

export interface CallStateResult {
  mode: CallWindowMode;
  isListening: boolean;
  assistantName: string;
  autoStartOnCall: boolean;
  /** The notes draft for the current target (preview event or live call). */
  notes: string;
  /**
   * Identity of whatever `notes` belongs to (event id or call id) — reload
   * the local draft only when this changes, not on every live refetch, or
   * typing would keep getting clobbered by the last-saved server value.
   */
  targetId: string | null;
  event: CallPreviewEvent | null;
  ended: CallEndedSummary | null;
}

export interface CallSpeaker {
  /** Voice fingerprint id (UUID string). */
  id: string;
  label: string;
  segmentCount: number;
}

export interface CallAttendee {
  id: string;
  name: string;
}

export interface CallTranscriptSegment {
  id: string;
  t0: number;
  t1: number;
  source: "mic" | "system";
  speaker: string | null;
  speakerId: string | null;
  /** "You" for mic, else the speaker label — precomputed to match native. */
  speakerLabel: string;
  text: string;
}

export interface CallTranscriptResult {
  isListening: boolean;
  eventTitle: string | null;
  speakers: CallSpeaker[];
  attendees: CallAttendee[];
  segments: CallTranscriptSegment[];
}

export interface CallAPI {
  "call.state": [Record<string, never>, CallStateResult];
  "call.transcript": [Record<string, never>, CallTranscriptResult];
  "call.saveNotes": [{ text: string }, Record<string, never>];
  "call.stop": [Record<string, never>, Record<string, never>];
  /** Empty name clears it (reverts to "Speaker N") — same as native. */
  "call.renameSpeaker": [{ id: string; name: string }, Record<string, never>];
  "call.copyTranscript": [Record<string, never>, Record<string, never>];
}
