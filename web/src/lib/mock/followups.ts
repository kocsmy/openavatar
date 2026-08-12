import { emitLocal } from "@/lib/bridge";
import type { FollowUp, FollowUpsSnapshot } from "@/lib/types/followups";
import type { MockHandlers } from "./index";

const delay = (ms = 120) => new Promise((r) => setTimeout(r, ms));
const hours = (n: number) => new Date(Date.now() + n * 3600_000).toISOString();
const days = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString();

let captureEnabled = true;

let scheduled: FollowUp[] = [
  {
    id: "fu-1",
    callID: "call-1",
    title: "Send Priya the revised JTM script IDs",
    quote: "yeah let's revisit the script IDs tomorrow once QA signs off",
    dueAt: hours(-20),
    createdAt: days(-1),
    status: "scheduled",
  },
  {
    id: "fu-2",
    callID: "call-2",
    title: "Check whether the Termly export finished overnight",
    quote: "I'll check the export in the morning",
    dueAt: hours(3),
    createdAt: hours(-5),
    status: "scheduled",
  },
  {
    id: "fu-3",
    callID: "call-2",
    title: "Follow up with legal on the redlined MSA",
    quote: "let's circle back on this tomorrow morning",
    dueAt: hours(26),
    createdAt: hours(-5),
    status: "scheduled",
  },
  {
    id: "fu-4",
    callID: "call-3",
    title: "Ping the design team about the onboarding flow mocks",
    quote: null,
    dueAt: days(4),
    createdAt: days(-2),
    status: "scheduled",
  },
];

let done: FollowUp[] = [
  {
    id: "fu-5",
    callID: "call-4",
    title: "Confirm the new API rate limits with the platform team",
    quote: "we should confirm the new rate limits before launch",
    dueAt: hours(-48),
    createdAt: days(-5),
    status: "done",
  },
];

function snapshot(): FollowUpsSnapshot {
  return {
    captureEnabled,
    scheduled: [...scheduled].sort((a, b) => a.dueAt.localeCompare(b.dueAt)),
    done: [...done].sort((a, b) => a.dueAt.localeCompare(b.dueAt)),
  };
}

/** Browser-only sample data for the followups surface. */
export const followupsMocks: MockHandlers = {
  "followups.list": async () => {
    await delay(120);
    return snapshot();
  },
  "followups.setCaptureEnabled": async (params) => {
    captureEnabled = Boolean(params.enabled);
    emitLocal("state");
    return {};
  },
  "followups.complete": async (params) => {
    const id = params.id as string;
    const found = scheduled.find((f) => f.id === id);
    if (found) {
      scheduled = scheduled.filter((f) => f.id !== id);
      done = [...done, { ...found, status: "done" }];
    }
    emitLocal("followups");
    return {};
  },
  "followups.snooze": async (params) => {
    const id = params.id as string;
    const addDays = params.days as number;
    scheduled = scheduled.map((f) =>
      f.id === id
        ? { ...f, dueAt: new Date(Math.max(new Date(f.dueAt).getTime(), Date.now()) + addDays * 86_400_000).toISOString() }
        : f,
    );
    emitLocal("followups");
    return {};
  },
  "followups.delete": async (params) => {
    const id = params.id as string;
    scheduled = scheduled.filter((f) => f.id !== id);
    done = done.filter((f) => f.id !== id);
    emitLocal("followups");
    return {};
  },
};
