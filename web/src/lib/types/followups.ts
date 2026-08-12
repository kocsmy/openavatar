/** Followups surface bridge contract. Mirrors Sources/OpenAvatar/WebUI/Bridges/FollowUpsBridge.swift. */

/** Only the two states this surface shows — "suggested" lives in the post-call
 * review, "dismissed" items don't resurface anywhere. */
export type FollowUpStatus = "scheduled" | "done";

export interface FollowUp {
  id: string;
  callID: string | null;
  title: string;
  quote: string | null;
  /** ISO 8601. */
  dueAt: string;
  /** ISO 8601. */
  createdAt: string;
  status: FollowUpStatus;
}

export interface FollowUpsSnapshot {
  captureEnabled: boolean;
  /** Soonest-due first. */
  scheduled: FollowUp[];
  /** Most-recently-due first isn't guaranteed — same soonest-due order as scheduled. */
  done: FollowUp[];
}

export interface FollowupsAPI {
  "followups.list": [Record<string, never>, FollowUpsSnapshot];
  "followups.setCaptureEnabled": [{ enabled: boolean }, Record<string, never>];
  "followups.complete": [{ id: string }, Record<string, never>];
  "followups.snooze": [{ id: string; days: number }, Record<string, never>];
  "followups.delete": [{ id: string }, Record<string, never>];
}
