import { emitLocal } from "@/lib/bridge";
import type {
  MenuApproval,
  MenuActionPlan,
  MenuDecision,
  MenuEvent,
  MenuExecutedAction,
  MenuIntent,
  MenuSnapshot,
  MenuSuggestion,
} from "@/lib/types/menu";
import type { MockHandlers } from "./index";

/*
 * Browser-only sample data for the menu-bar popover. The story: an active call,
 * one item already prepared for approval, one detected item still below the
 * confidence threshold (greyed out), a couple of things already executed, and
 * a stale error — so every section the popover can show is visible at once for
 * review/screenshots.
 */

const delay = (ms = 150) => new Promise((r) => setTimeout(r, ms));
const hours = (n: number) => new Date(Date.now() + n * 3600_000).toISOString();
const uid = () => Math.random().toString(36).slice(2, 10);

let isListening = true;
let systemAudioActive = true;
let isPlanning = false;
let isConsolidating = false;
// Only surfaces once idle (toggle "Stop" to see the call-suggestion banner) —
// mirrors AppState.suggestedCallApp being ignored while already listening.
let suggestedCallApp: string | null = "Zoom";
let lastError: string | null =
  "HTTP 403: GitHub API rate limit exceeded for token ending •••4f2a. Wait a few minutes and retry.";
let errorLogCount = 2;

const upcoming: MenuEvent[] = [
  {
    id: "evt-1",
    title: "Design review — onboarding flow",
    startISO: hours(2),
    endISO: hours(2.5),
    conferenceService: "Google Meet",
    participantSummary: "Priya + 2 more",
  },
  {
    id: "evt-2",
    title: "1:1 with Alice",
    startISO: hours(19),
    endISO: hours(19.5),
    conferenceService: null,
    participantSummary: "Alice Ng",
  },
];

let suggestions: MenuSuggestion[] = [
  {
    id: "sug-1",
    title: "You promised Alice the pricing doc by Friday",
    rationale: "Mentioned in your 1:1 last week — no follow-up sent yet.",
  },
];

let detected: MenuDecision[] = [
  {
    id: "dec-2",
    summary: "Send Ben the updated API rate limits",
    quote: "I'll send Ben the new rate limits after this",
    intent: "send_message",
    confidence: 0.74,
  },
  {
    id: "dec-3",
    summary: "Merge the hotfix PR once CI is green",
    quote: "merge it once CI passes",
    intent: "merge_pr",
    confidence: 0.41,
  },
];

let approvals: MenuApproval[] = [
  {
    id: "appr-1",
    decision: {
      id: "dec-1",
      summary: "Create Linear ticket for the export timeout bug",
      quote: "yeah let's file a ticket for that export timeout",
      intent: "create_ticket",
      confidence: 0.82,
    },
    plan: {
      id: "plan-1",
      decisionID: "dec-1",
      steps: [
        {
          id: "step-1",
          integration: "linear",
          tool: "create_issue",
          arguments: {
            title: "Fix export timeout on large workspaces",
            team: "ENG",
            description: "Exports over 5k rows are timing out — reported on today's call.",
          },
          riskClass: "write",
        },
      ],
      riskClass: "write",
      preview: {
        title: "Create Linear ticket: Fix export timeout on large workspaces",
        detail:
          "Team: ENG\nTitle: Fix export timeout on large workspaces\n\nExports over 5k rows are timing out — reported on today's call.",
      },
    },
    edited: false,
  },
];

let executed: MenuExecutedAction[] = [
  {
    id: "exec-1",
    summary: "Posted message to #eng-alerts",
    url: "https://openavatar-team.slack.com/archives/C123/p1700000000",
    undone: false,
    canUndo: true,
  },
  {
    id: "exec-2",
    summary: "Created Linear ticket ENG-482",
    url: "https://linear.app/openavatar/issue/ENG-482",
    undone: true,
    canUndo: false,
  },
];

/** Mirrors MenuBridge.planFor — a plausible plan/preview per intent, for the mock only. */
function planFor(decision: MenuDecision): MenuActionPlan {
  const table: Record<MenuIntent, { integration: string; tool: string; risk: "read" | "draft" | "write" | "destructive" }> = {
    create_ticket: { integration: "linear", tool: "create_issue", risk: "write" },
    code_change: { integration: "github", tool: "propose_change", risk: "write" },
    send_message: { integration: "slack", tool: "send_message", risk: "write" },
    send_email: { integration: "email", tool: "send_email", risk: "write" },
    merge_pr: { integration: "github", tool: "merge_pr", risk: "destructive" },
    other: { integration: "email", tool: "draft_email", risk: "draft" },
  };
  const { integration, tool, risk } = table[decision.intent];
  return {
    id: uid(),
    decisionID: decision.id,
    steps: [
      {
        id: uid(),
        integration,
        tool,
        arguments: { summary: decision.summary, quote: decision.quote },
        riskClass: risk,
      },
    ],
    riskClass: risk,
    preview: {
      title: decision.summary,
      detail: `"${decision.quote}"`,
    },
  };
}

function snapshot(): MenuSnapshot {
  return {
    isListening,
    systemAudioActive,
    isPlanning,
    isConsolidating,
    suggestedCallApp,
    lastError,
    errorLogCount,
    upcoming,
    suggestions: [...suggestions],
    approvals: [...approvals],
    detected: [...detected],
    executed: [...executed],
  };
}

/** Browser-only sample data for the menu surface. */
export const menuMocks: MockHandlers = {
  "menu.snapshot": async () => {
    await delay(100);
    return snapshot();
  },
  "menu.toggleListening": async () => {
    isListening = !isListening;
    if (!isListening) systemAudioActive = false;
    emitLocal("state");
    return {};
  },
  "menu.openEventNotes": async () => {
    // Opens a window in the real app; nothing to simulate here.
    return {};
  },
  "menu.prepareSuggestion": async (params) => {
    const id = params.id as string;
    const suggestion = suggestions.find((s) => s.id === id);
    if (!suggestion) return {};
    suggestions = suggestions.filter((s) => s.id !== id);
    const decision: MenuDecision = {
      id: uid(),
      summary: suggestion.title,
      quote: suggestion.rationale,
      intent: "send_email",
      confidence: 1,
    };
    detected = [...detected, decision];
    emitLocal("state");
    isPlanning = true;
    emitLocal("state");
    await delay(700);
    approvals = [...approvals, { id: uid(), decision, plan: planFor(decision), edited: false }];
    isPlanning = false;
    emitLocal("state");
    return {};
  },
  "menu.dismissSuggestion": async (params) => {
    const id = params.id as string;
    suggestions = suggestions.filter((s) => s.id !== id);
    emitLocal("state");
    return {};
  },
  "menu.prepareDecision": async (params) => {
    const decisionID = params.decisionID as string;
    if (approvals.some((a) => a.decision.id === decisionID)) return {};
    const decision = detected.find((d) => d.id === decisionID);
    if (!decision) return {};
    isPlanning = true;
    emitLocal("state");
    await delay(700);
    approvals = [...approvals, { id: uid(), decision, plan: planFor(decision), edited: false }];
    isPlanning = false;
    emitLocal("state");
    return {};
  },
  "menu.markDone": async (params) => {
    const decisionID = params.decisionID as string;
    approvals = approvals.filter((a) => a.decision.id !== decisionID);
    detected = detected.filter((d) => d.id !== decisionID);
    emitLocal("state");
    return {};
  },
  "menu.dismissDecision": async (params) => {
    const decisionID = params.decisionID as string;
    approvals = approvals.filter((a) => a.decision.id !== decisionID);
    detected = detected.filter((d) => d.id !== decisionID);
    emitLocal("state");
    return {};
  },
  "menu.approve": async (params) => {
    const approvalID = params.approvalID as string;
    const approval = approvals.find((a) => a.id === approvalID);
    if (!approval) return {};
    approvals = approvals.filter((a) => a.id !== approvalID);
    detected = detected.filter((d) => d.id !== approval.decision.id);
    executed = [
      {
        id: uid(),
        summary: approval.plan.preview.title,
        url: null,
        undone: false,
        canUndo: true,
      },
      ...executed,
    ];
    emitLocal("state");
    return {};
  },
  "menu.updateApproval": async (params) => {
    const approvalID = params.approvalID as string;
    const stepID = params.stepID as string;
    const editedArguments = params.editedArguments as Record<string, unknown>;
    approvals = approvals.map((a) => {
      if (a.id !== approvalID) return a;
      const steps = a.plan.steps.map((s) =>
        s.id === stepID ? { ...s, arguments: editedArguments as MenuApproval["plan"]["steps"][number]["arguments"] } : s,
      );
      return { ...a, edited: true, plan: { ...a.plan, steps } };
    });
    emitLocal("state");
    return {};
  },
  "menu.undo": async (params) => {
    const actionID = params.actionID as string;
    executed = executed.map((a) => (a.id === actionID ? { ...a, undone: true } : a));
    emitLocal("state");
    return {};
  },
  "menu.clearErrors": async () => {
    lastError = null;
    errorLogCount = 0;
    emitLocal("state");
    return {};
  },
  "menu.quit": async () => {
    return {};
  },
};
