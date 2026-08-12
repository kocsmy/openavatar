import { emitLocal } from "@/lib/bridge";
import type {
  CallAttendee,
  CallEndedSummary,
  CallSpeaker,
  CallStateResult,
  CallTranscriptResult,
  CallTranscriptSegment,
  CallWindowMode,
} from "@/lib/types/call";
import type { MockHandlers } from "./index";

const delay = (ms = 100) => new Promise((r) => setTimeout(r, ms));

/*
 * Browser-only sample data: a call already a few minutes in, one voice still
 * unnamed so the rename/assign affordances have something to do, and a Stop
 * button that walks the state machine into the "ended" handoff card — the
 * same transition CallBridge.state() drives natively.
 */

let mode: CallWindowMode = "live";
let notes =
  "- Confirm the Termly export finished\n- Ask about the redlined MSA timeline\n";

const attendees: CallAttendee[] = [
  { id: "priya@acme.com", name: "Priya Patel" },
  { id: "sam@acme.com", name: "Sam Ortiz" },
];

const speakers: CallSpeaker[] = [
  { id: "sp-1", label: "Priya Patel", segmentCount: 6 },
  { id: "sp-2", label: "Speaker 2", segmentCount: 3 },
];

let segments: CallTranscriptSegment[] = [
  { id: "s1", t0: 2, t1: 5, source: "mic", speaker: null, speakerId: null, speakerLabel: "You", text: "Okay, recording — let's start with the Termly export." },
  { id: "s2", t0: 6, t1: 12, source: "system", speaker: "Priya Patel", speakerId: "sp-1", speakerLabel: "Priya Patel", text: "Sure. It kicked off last night, should be done by the time we wrap up here." },
  { id: "s3", t0: 13, t1: 15, source: "mic", speaker: null, speakerId: null, speakerLabel: "You", text: "Great, I'll check the export in the morning either way." },
  { id: "s4", t0: 17, t1: 24, source: "system", speaker: "Speaker 2", speakerId: "sp-2", speakerLabel: "Speaker 2", text: "Before that — do we know when legal is getting back to us on the MSA?" },
  { id: "s5", t0: 25, t1: 30, source: "system", speaker: "Priya Patel", speakerId: "sp-1", speakerLabel: "Priya Patel", text: "Let's circle back on this tomorrow morning, I haven't heard from them yet." },
  { id: "s6", t0: 31, t1: 34, source: "mic", speaker: null, speakerId: null, speakerLabel: "You", text: "Works for me. I'll follow up with legal on the redlined MSA myself." },
  { id: "s7", t0: 36, t1: 41, source: "system", speaker: "Speaker 2", speakerId: "sp-2", speakerLabel: "Speaker 2", text: "Sounds good — one more thing, the design mocks for onboarding are close." },
  { id: "s8", t0: 42, t1: 45, source: "mic", speaker: null, speakerId: null, speakerLabel: "You", text: "Nice, ping the design team once those land." },
];

let endedSummary: CallEndedSummary | null = null;

function state(): CallStateResult {
  return {
    mode,
    isListening: mode === "live",
    assistantName: "Avatar",
    autoStartOnCall: true,
    notes: mode === "ended" ? "" : notes,
    targetId: mode === "ended" ? null : "call-live-1",
    event: null,
    ended: mode === "ended" ? endedSummary : null,
  };
}

function transcriptResult(): CallTranscriptResult {
  return {
    isListening: mode === "live",
    eventTitle: "Sync with Acme",
    speakers,
    attendees,
    segments,
  };
}

/** Browser-only sample data for the call surface. */
export const callMocks: MockHandlers = {
  "call.state": async () => {
    await delay();
    return state();
  },
  "call.transcript": async () => {
    await delay();
    return transcriptResult();
  },
  "call.saveNotes": async (params) => {
    notes = String(params.text ?? "");
    return {};
  },
  "call.stop": async () => {
    mode = "ended";
    endedSummary = {
      callID: "call-acme",
      title: "Sync with Acme",
      startedAt: new Date(Date.now() - 42_000).toISOString(),
      endedAt: new Date().toISOString(),
      appName: "Google Meet",
      notes: null,
      summary: null,
      isConsolidating: true,
    };
    emitLocal("state");
    // Consolidation "finishes" a moment later, same as the real pipeline.
    void delay(1800).then(() => {
      if (!endedSummary) return;
      endedSummary = {
        ...endedSummary,
        isConsolidating: false,
        notes: "## Summary\nDiscussed the Termly export and the redlined MSA timeline.\n\n## Decisions\n- Follow up with legal on the MSA\n- Ping design once onboarding mocks land",
      };
      emitLocal("state");
    });
    return {};
  },
  "call.renameSpeaker": async (params) => {
    const id = String(params.id ?? "");
    const name = String(params.name ?? "").trim();
    const speaker = speakers.find((s) => s.id === id);
    if (speaker) speaker.label = name || "Speaker 2";
    segments = segments.map((seg) =>
      seg.speakerId === id ? { ...seg, speaker: name || "Speaker 2", speakerLabel: name || "Speaker 2" } : seg,
    );
    emitLocal("state");
    return {};
  },
  "call.copyTranscript": async () => {
    const text = segments
      .map((s) => `[${String(Math.floor(s.t0 / 60)).padStart(2, "0")}:${String(Math.floor(s.t0 % 60)).padStart(2, "0")}] ${s.speakerLabel}: ${s.text}`)
      .join("\n");
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // Best-effort in the browser sandbox — the native host always succeeds.
    }
    return {};
  },
};
