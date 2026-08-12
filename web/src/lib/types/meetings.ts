/** Meetings surface bridge contract. Mirrors Sources/OpenAvatar/WebUI/Bridges/MeetingsBridge.swift. */

export type MeetingAudioSource = "mic" | "system";

/** Raw values match Swift's DecisionStatus.rawValue exactly. */
export type DecisionStatus =
  | "detected"
  | "approved"
  | "edited"
  | "dismissed"
  | "executed"
  | "done_myself"
  | "reverted";

/** Raw values match Swift's FollowUpStatus.rawValue exactly. */
export type FollowUpStatus = "suggested" | "scheduled" | "done" | "dismissed";

/** Raw values match Swift's DismissReason.rawValue exactly. */
export type DismissReason = "wrong_transcription" | "wrong_intent" | "not_actionable" | "duplicate" | "other";

export interface MeetingSummary {
  id: string;
  startedAt: string;
  endedAt: string | null;
  app: string | null;
  title: string | null;
  summary: string | null;
}

export interface MeetingSegment {
  id: string;
  t0: number;
  source: MeetingAudioSource;
  speaker: string | null;
  speakerID: string | null;
  text: string;
}

export interface MeetingSpeaker {
  id: string;
  name: string | null;
  ordinal: number;
  sampleCount: number;
}

export interface MeetingDecision {
  id: string;
  summary: string;
  quote: string;
  status: DecisionStatus;
}

export interface MeetingFollowUp {
  id: string;
  title: string;
  dueAt: string;
  status: FollowUpStatus;
}

export interface MeetingDetail {
  call: MeetingSummary & { notes: string | null; userNotes: string | null };
  /** Non-null when this is the call currently being consolidated and its draft notes beat the store's snapshot. */
  liveNotes: string | null;
  isConsolidating: boolean;
  isListening: boolean;
  segments: MeetingSegment[];
  /** Voices heard on this call. */
  speakers: MeetingSpeaker[];
  /** Every known voice, for the "merge into…" target list. */
  allSpeakers: MeetingSpeaker[];
  decisions: MeetingDecision[];
  followUps: MeetingFollowUp[];
}

/** One exchange in an "ask" thread. Only user/assistant cross the bridge. */
export interface ChatTurn {
  role: "user" | "assistant";
  content: string;
}

export interface ChatAnswer {
  answer: string;
  /** Meetings the answer drew on, for citation chips. */
  callIDs: string[];
}

export interface MeetingsAPI {
  "meetings.list": [Record<string, never>, { meetings: MeetingSummary[] }];
  "meetings.detail": [{ callID: string }, MeetingDetail];
  "meetings.delete": [{ callID: string }, Record<string, never>];
  "meetings.renameSpeaker": [{ speakerID: string; name: string | null }, Record<string, never>];
  "meetings.mergeSpeaker": [{ sourceID: string; targetID: string }, Record<string, never>];
  "meetings.detachSpeaker": [{ callID: string; speakerID: string }, Record<string, never>];
  "meetings.sweepStrayVoices": [Record<string, never>, { foldedCount: number }];
  "meetings.prepareDecision": [{ callID: string; decisionID: string }, Record<string, never>];
  "meetings.markDecisionDone": [{ callID: string; decisionID: string }, Record<string, never>];
  "meetings.dismissDecision": [
    { callID: string; decisionID: string; reason: DismissReason },
    Record<string, never>,
  ];
  "meetings.confirmFollowUp": [{ callID: string; followUpID: string }, Record<string, never>];
  "meetings.dismissFollowUp": [{ callID: string; followUpID: string }, Record<string, never>];
  "meetings.copyTranscript": [{ callID: string }, { message: string }];
  "meetings.exportMarkdown": [{ callID: string }, { message: string }];
  "meetings.saveUserNotes": [{ callID: string; notes: string }, Record<string, never>];
  /**
   * Follow-up question about one meeting. Pass `streamID` (from openStream) to
   * receive the answer as it is written; the call still resolves with all of it.
   */
  "meetings.ask": [
    { callID: string; question: string; history: ChatTurn[]; streamID?: string },
    ChatAnswer,
  ];
  /** Question across the whole library — the model picks which calls to read. */
  "meetings.search": [{ query: string; history: ChatTurn[]; streamID?: string }, ChatAnswer];
}
