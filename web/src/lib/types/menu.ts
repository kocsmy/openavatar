/** Menu surface bridge contract. Mirrors Sources/OpenAvatar/WebUI/Bridges/MenuBridge.swift. */

/** Mirrors DecisionIntent (Core/Models.swift). */
export type MenuIntent = "create_ticket" | "code_change" | "send_message" | "send_email" | "merge_pr" | "other";

/** Mirrors DismissReason (Core/Models.swift). */
export type MenuDismissReason = "wrong_transcription" | "wrong_intent" | "not_actionable" | "duplicate" | "other";

/** Mirrors RiskClass (Core/Models.swift). */
export type MenuRiskClass = "read" | "draft" | "write" | "destructive";

/** Structural mirror of Swift's JSONValue — arbitrary tool-call arguments. */
export type MenuJSONValue =
  | null
  | boolean
  | number
  | string
  | MenuJSONValue[]
  | { [key: string]: MenuJSONValue };

export interface MenuDecision {
  id: string;
  summary: string;
  quote: string;
  intent: MenuIntent;
  confidence: number;
}

export interface MenuActionStep {
  id: string;
  integration: string;
  tool: string;
  arguments: Record<string, MenuJSONValue>;
  riskClass: MenuRiskClass;
}

export interface MenuActionPlan {
  id: string;
  decisionID: string;
  steps: MenuActionStep[];
  riskClass: MenuRiskClass;
  preview: { title: string; detail: string };
}

export interface MenuApproval {
  id: string;
  decision: MenuDecision;
  plan: MenuActionPlan;
  edited: boolean;
}

export interface MenuSuggestion {
  id: string;
  title: string;
  rationale: string;
}

export interface MenuExecutedAction {
  id: string;
  summary: string;
  url: string | null;
  undone: boolean;
  canUndo: boolean;
}

/** An upcoming meeting, already filtered/capped the way the popover shows it. */
export interface MenuEvent {
  id: string;
  title: string;
  startISO: string | null;
  endISO: string | null;
  conferenceService: string | null;
  participantSummary: string | null;
}

export interface MenuSnapshot {
  isListening: boolean;
  systemAudioActive: boolean;
  isPlanning: boolean;
  isConsolidating: boolean;
  /** Non-null only when a likely call app is active and we're not already listening. */
  suggestedCallApp: string | null;
  lastError: string | null;
  /** app.errorLog.count — drives the "N errors this session" footnote. */
  errorLogCount: number;
  upcoming: MenuEvent[];
  suggestions: MenuSuggestion[];
  approvals: MenuApproval[];
  detected: MenuDecision[];
  executed: MenuExecutedAction[];
}

/** method name → [params, result] */
export interface MenuAPI {
  "menu.snapshot": [Record<string, never>, MenuSnapshot];
  "menu.toggleListening": [Record<string, never>, Record<string, never>];
  /** Open an upcoming meeting's notes ahead of the call (Granola-style pre-write). */
  "menu.openEventNotes": [{ eventID: string }, Record<string, never>];
  /** "Prepare" on a proactive suggestion — turns it into a decision and starts planning. */
  "menu.prepareSuggestion": [{ id: string }, Record<string, never>];
  "menu.dismissSuggestion": [{ id: string }, Record<string, never>];
  /** "Prepare" on a detected decision — generates its plan/preview on demand. */
  "menu.prepareDecision": [{ decisionID: string }, Record<string, never>];
  /** "I already did this myself" — clears the item without executing or logging a misfire. */
  "menu.markDone": [{ decisionID: string }, Record<string, never>];
  "menu.dismissDecision": [{ decisionID: string; reason: MenuDismissReason }, Record<string, never>];
  "menu.approve": [{ approvalID: string }, Record<string, never>];
  "menu.updateApproval": [
    { approvalID: string; stepID: string; editedArguments: Record<string, MenuJSONValue> },
    Record<string, never>,
  ];
  "menu.undo": [{ actionID: string }, Record<string, never>];
  "menu.clearErrors": [Record<string, never>, Record<string, never>];
  "menu.quit": [Record<string, never>, Record<string, never>];
}
