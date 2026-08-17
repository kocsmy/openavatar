import { emitLocal, emitStreamLocal } from "@/lib/bridge";
import type {
  DecisionStatus,
  FollowUpStatus,
  MeetingDecision,
  MeetingFollowUp,
  MeetingSegment,
  MeetingSpeaker,
  MeetingSummary,
} from "@/lib/types/meetings";
import type { MockHandlers } from "./index";

/*
 * Browser-only sample data: a couple of finished calls (one with structured
 * notes and live actions, one already resolved), a legacy call with only the
 * old ";"-joined digest, and an empty one to exercise every empty state.
 */
const delay = (ms = 150) => new Promise((r) => setTimeout(r, ms));

function hoursAgo(h: number): string {
  return new Date(Date.now() - h * 3_600_000).toISOString();
}

function daysAgo(d: number, hour: number, minute = 0): string {
  const dt = new Date();
  dt.setDate(dt.getDate() - d);
  dt.setHours(hour, minute, 0, 0);
  return dt.toISOString();
}

// MARK: Speaker registry — spans every meeting, like the real fingerprint store.

type MockSpeaker = MeetingSpeaker;

const speakers: MockSpeaker[] = [
  { id: "spk-alice", name: "Alice Ng", ordinal: 1, sampleCount: 42 },
  { id: "spk-ben", name: "Ben Ortiz", ordinal: 2, sampleCount: 31 },
  { id: "spk-vasilis", name: "Vasilis", ordinal: 3, sampleCount: 18 },
  { id: "spk-stray", name: null, ordinal: 4, sampleCount: 2 },
];

// MARK: Meetings

interface MockMeeting {
  id: string;
  startedAt: string;
  endedAt: string | null;
  app: string | null;
  title: string | null;
  summary: string | null;
  notes: string | null;
  userNotes: string | null;
  speakerIDs: string[];
  segments: MeetingSegment[];
  decisions: MeetingDecision[];
  followUps: MeetingFollowUp[];
}

const meetings: MockMeeting[] = [
  {
    id: "call-acme",
    startedAt: hoursAgo(2),
    endedAt: hoursAgo(1.2),
    app: "Google Meet",
    title: "Sync with Acme",
    summary: null,
    notes:
      "# Sync with Acme\n" +
      "- Termly export finished overnight, Alice confirmed the numbers match\n" +
      "  - No action needed, just a sanity check\n" +
      "- Redlined MSA is still with Acme's legal team\n" +
      "- Onboarding mocks are close to ready for review\n" +
      "\n" +
      "## Decisions\n" +
      "- Ben will ping legal tomorrow if there's no word on the MSA\n" +
      "- Ship the onboarding mocks to design review once Alice signs off",
    userNotes: "Remember to loop in Priya before we touch the pricing page.",
    speakerIDs: ["spk-alice", "spk-ben"],
    segments: [
      { id: "seg-1", t0: 3, source: "mic", speaker: null, speakerID: null, text: "Okay, recording — let's start with the Termly export." },
      { id: "seg-2", t0: 9, source: "system", speaker: "Alice Ng", speakerID: "spk-alice", text: "It kicked off last night, the numbers match what we expected." },
      { id: "seg-3", t0: 18, source: "mic", speaker: null, speakerID: null, text: "Great, one less thing to worry about." },
      { id: "seg-4", t0: 24, source: "system", speaker: "Ben Ortiz", speakerID: "spk-ben", text: "Before we move on — any word from legal on the redlined MSA?" },
      { id: "seg-5", t0: 33, source: "system", speaker: "Alice Ng", speakerID: "spk-alice", text: "Nothing yet, I'll chase them again tomorrow morning if it's still quiet." },
      { id: "seg-6", t0: 44, source: "mic", speaker: null, speakerID: null, text: "Sounds good. Ben, can you follow up with legal if she doesn't hear back?" },
      { id: "seg-7", t0: 52, source: "system", speaker: "Ben Ortiz", speakerID: "spk-ben", text: "Yep, I'll take it tomorrow. Also — onboarding mocks are almost done." },
      { id: "seg-8", t0: 61, source: "mic", speaker: null, speakerID: null, text: "Nice, send them to design review as soon as they're ready." },
    ],
    decisions: [
      { id: "dec-1", summary: "Ben follows up with Acme's legal team on the redlined MSA", quote: "Yep, I'll take it tomorrow.", status: "detected" },
      { id: "dec-2", summary: "Ship onboarding mocks to design review", quote: "Nice, send them to design review as soon as they're ready.", status: "approved" },
    ],
    followUps: [
      { id: "fu-1", title: "Check the Termly export landed cleanly", dueAt: hoursAgo(-22), status: "suggested" },
    ],
  },
  {
    id: "call-vasilis",
    startedAt: daysAgo(1, 15),
    endedAt: daysAgo(1, 15, 30),
    app: "Zoom",
    title: "1:1 with Vasilis",
    summary: null,
    notes:
      "# 1:1 with Vasilis\n" +
      "- Reviewed the GA4/GTM handoff for the new pricing page\n" +
      "- Agreed to send over the JTM script IDs\n" +
      "\n" +
      "## Decisions\n" +
      "- Send the JTM script IDs by tomorrow",
    userNotes: null,
    speakerIDs: ["spk-vasilis"],
    segments: [
      { id: "seg-9", t0: 5, source: "mic", speaker: null, speakerID: null, text: "So where are we on the GA4 handoff?" },
      { id: "seg-10", t0: 12, source: "system", speaker: "Vasilis", speakerID: "spk-vasilis", text: "Mostly done, I just need the JTM script IDs from your side." },
      { id: "seg-11", t0: 20, source: "mic", speaker: null, speakerID: null, text: "I'll send those over myself later today." },
    ],
    decisions: [
      { id: "dec-3", summary: "Send the JTM script IDs to Vasilis", quote: "I'll send those over myself later today.", status: "done_myself" },
    ],
    followUps: [
      { id: "fu-2", title: "Confirm GTM handoff is fully wired up", dueAt: daysAgo(-2, 10), status: "scheduled" },
    ],
  },
  {
    id: "call-legacy",
    startedAt: daysAgo(6, 11),
    endedAt: daysAgo(6, 11, 24),
    app: "zoom.us",
    title: null,
    summary:
      "Reviewed churn numbers for June; still the top concern. Filed a follow-up on the pricing experiment; Discussed hiring for the design role.",
    notes: null,
    userNotes: null,
    speakerIDs: ["spk-stray"],
    segments: [
      { id: "seg-12", t0: 4, source: "mic", speaker: null, speakerID: null, text: "Let's go through the June numbers." },
      { id: "seg-13", t0: 11, source: "system", speaker: "Speaker 4", speakerID: "spk-stray", text: "Churn's still the biggest line item, unfortunately." },
    ],
    decisions: [],
    followUps: [],
  },
  {
    id: "call-empty",
    startedAt: daysAgo(9, 9),
    endedAt: daysAgo(9, 9, 3),
    app: "Slack",
    title: null,
    summary: null,
    notes: null,
    userNotes: null,
    speakerIDs: [],
    segments: [],
    decisions: [],
    followUps: [],
  },
];

const listening = false;

function summaryOf(m: MockMeeting): MeetingSummary {
  return { id: m.id, startedAt: m.startedAt, endedAt: m.endedAt, app: m.app, title: m.title, summary: m.summary };
}

function findMeeting(id: unknown): MockMeeting | undefined {
  return meetings.find((m) => m.id === id);
}

function speakerOf(id: string): MockSpeaker | undefined {
  return speakers.find((s) => s.id === id);
}

function plainTextTranscript(m: MockMeeting): string {
  return m.segments
    .map((s) => {
      const at = new Date(new Date(m.startedAt).getTime() + s.t0 * 1000);
      const label = s.source === "mic" ? "You" : (s.speaker ?? "Others");
      return `[${at.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" })}] ${label}: ${s.text}`;
    })
    .join("\n");
}

export const meetingsMocks: MockHandlers = {
  "meetings.list": async () => {
    await delay();
    return { meetings: meetings.map(summaryOf) };
  },
  "meetings.detail": async (params) => {
    await delay();
    const m = findMeeting(params.callID);
    if (!m) throw new Error("Unknown meeting");
    return {
      call: { ...summaryOf(m), notes: m.notes, userNotes: m.userNotes },
      liveNotes: null,
      isConsolidating: false,
      isListening: listening,
      segments: m.segments,
      speakers: m.speakerIDs.map(speakerOf).filter((s): s is MockSpeaker => Boolean(s)),
      allSpeakers: speakers,
      decisions: m.decisions,
      followUps: m.followUps,
    };
  },
  "meetings.delete": async (params) => {
    const i = meetings.findIndex((m) => m.id === params.callID);
    if (i >= 0) meetings.splice(i, 1);
    emitLocal("meetings");
    return {};
  },
  "meetings.renameSpeaker": async (params) => {
    const s = speakerOf(String(params.speakerID ?? ""));
    if (s) s.name = (params.name as string | null) ?? null;
    emitLocal("meetings");
    return {};
  },
  "meetings.mergeSpeaker": async (params) => {
    const source = speakerOf(String(params.sourceID ?? ""));
    const target = speakerOf(String(params.targetID ?? ""));
    if (source && target) {
      if (!target.name && source.name) target.name = source.name;
      target.sampleCount += source.sampleCount;
      for (const m of meetings) {
        m.speakerIDs = m.speakerIDs.map((id) => (id === source.id ? target.id : id));
        m.segments = m.segments.map((seg) =>
          seg.speakerID === source.id
            ? { ...seg, speakerID: target.id, speaker: target.name ?? `Speaker ${target.ordinal}` }
            : seg,
        );
      }
      const idx = speakers.findIndex((s) => s.id === source.id);
      if (idx >= 0) speakers.splice(idx, 1);
    }
    emitLocal("meetings");
    return {};
  },
  "meetings.detachSpeaker": async (params) => {
    const m = findMeeting(params.callID);
    const sourceID = String(params.speakerID ?? "");
    if (m && m.segments.some((s) => s.speakerID === sourceID)) {
      const ordinal = Math.max(0, ...speakers.map((s) => s.ordinal)) + 1;
      const fresh: MockSpeaker = { id: `spk-${ordinal}`, name: null, ordinal, sampleCount: 1 };
      speakers.push(fresh);
      m.speakerIDs = m.speakerIDs.map((id) => (id === sourceID ? fresh.id : id));
      m.segments = m.segments.map((seg) =>
        seg.speakerID === sourceID ? { ...seg, speakerID: fresh.id, speaker: `Speaker ${ordinal}` } : seg,
      );
    }
    emitLocal("meetings");
    return {};
  },
  "meetings.prepareDecision": async () => {
    await delay(400);
    return {};
  },
  "meetings.markDecisionDone": async (params) => {
    const m = findMeeting(params.callID);
    const d = m?.decisions.find((x) => x.id === params.decisionID);
    if (d) d.status = "done_myself" satisfies DecisionStatus;
    emitLocal("meetings");
    return {};
  },
  "meetings.dismissDecision": async (params) => {
    const m = findMeeting(params.callID);
    const d = m?.decisions.find((x) => x.id === params.decisionID);
    if (d) d.status = "dismissed" satisfies DecisionStatus;
    emitLocal("meetings");
    return {};
  },
  "meetings.confirmFollowUp": async (params) => {
    const m = findMeeting(params.callID);
    const f = m?.followUps.find((x) => x.id === params.followUpID);
    if (f) f.status = "scheduled" satisfies FollowUpStatus;
    emitLocal("meetings");
    return {};
  },
  "meetings.dismissFollowUp": async (params) => {
    const m = findMeeting(params.callID);
    const f = m?.followUps.find((x) => x.id === params.followUpID);
    if (f) f.status = "dismissed" satisfies FollowUpStatus;
    emitLocal("meetings");
    return {};
  },
  "meetings.copyTranscript": async (params) => {
    const m = findMeeting(params.callID);
    if (m) {
      try {
        await navigator.clipboard.writeText(plainTextTranscript(m));
      } catch {
        // Best-effort in the browser sandbox — the native host always succeeds.
      }
    }
    return { message: "Copied" };
  },
  "meetings.exportMarkdown": async (params) => {
    const m = findMeeting(params.callID);
    if (!m) return { message: "" };
    const day = m.startedAt.slice(0, 10);
    return { message: `Exported to transcript-${day}.md` };
  },
  "meetings.saveUserNotes": async (params) => {
    const m = findMeeting(params.callID);
    if (m) m.userNotes = String(params.notes ?? "");
    emitLocal("meetings");
    return {};
  },
  // The real answers come from the configured model; the mock just proves the
  // round trip so the composer can be developed in a browser.
  "meetings.ask": async (params) => {
    await delay(700);
    const m = findMeeting(params.callID);
    const answer = m
      ? `**Mock answer** — nothing in “${m.title ?? "this call"}” addresses “${params.question}” directly. What it does cover:\n\n- The pricing experiment, briefly\n- Hiring for the design role\n2. A follow-up nobody owned`
      : "(mock answer) That meeting isn't in the library.";
    await typeOut(String(params.streamID ?? ""), answer);
    return { answer, callIDs: m ? [m.id] : [] };
  },
  "meetings.search": async (params) => {
    await delay(900);
    const hits = meetings
      .filter((m) => `${m.title ?? ""} ${m.summary ?? ""}`.toLowerCase().includes(String(params.query ?? "").toLowerCase()))
      .slice(0, 3);
    const answer = hits.length
      ? `**Mock answer** — ${hits.length} meeting${hits.length > 1 ? "s" : ""} mention that.`
      : "(mock answer) Nothing in the library covers that.";
    await typeOut(String(params.streamID ?? ""), answer);
    return { answer, callIDs: hits.map((m) => m.id) };
  },
};

/** Imitates the host's token push so streaming is developable in a browser. */
async function typeOut(streamID: string, answer: string) {
  if (!streamID) return;
  for (const word of answer.split(/(\s+)/)) {
    emitStreamLocal(streamID, word);
    await delay(18);
  }
}
