import type { MockHandlers } from "./index";
import { emitLocal } from "@/lib/bridge";
import type { HomeEvent, HomeSnapshot } from "../types/home";

/** Browser-only sample data for the home surface — a plausible "Coming up" week. */
const now = new Date();

function atOffsetMinutes(minutes: number): string {
  return new Date(now.getTime() + minutes * 60_000).toISOString();
}

function atDay(dayOffset: number, hour: number, minute = 0): string {
  const d = new Date(now);
  d.setDate(d.getDate() + dayOffset);
  d.setHours(hour, minute, 0, 0);
  return d.toISOString();
}

let isListening = false;
const autoStartOnCall = true;
const calendarEnabled = true;

const events: HomeEvent[] = [
  {
    id: "evt-standup",
    title: "Standup w/ Design",
    start: atOffsetMinutes(-8),
    end: atOffsetMinutes(17),
    conferenceService: "Google Meet",
    participantSummary: "Alice + 2 more",
    isNow: true,
  },
  {
    id: "evt-1-1",
    title: "1:1 with Ben",
    start: atDay(0, 15, 30),
    end: atDay(0, 16, 0),
    conferenceService: "Zoom",
    participantSummary: "Ben Ortiz",
    isNow: false,
  },
  {
    id: "evt-acme",
    title: "Sync with Acme",
    start: atDay(1, 10, 0),
    end: atDay(1, 10, 30),
    conferenceService: "Google Meet",
    participantSummary: "Salim + 3 more",
    isNow: false,
  },
  {
    id: "evt-review",
    title: "Product review",
    start: atDay(3, 13, 0),
    end: atDay(3, 14, 0),
    conferenceService: null,
    participantSummary: "Vasilis",
    isNow: false,
  },
];

function snapshot(): HomeSnapshot {
  return { isListening, autoStartOnCall, calendarEnabled, events };
}

export const homeMocks: MockHandlers = {
  "home.snapshot": async () => snapshot(),
  "home.refresh": async () => ({}),
  "home.startListening": async () => {
    isListening = true;
    emitLocal("state");
    return {};
  },
  "home.stopListening": async () => {
    isListening = false;
    emitLocal("state");
    return {};
  },
  "home.openEventNotes": async () => ({}),
};
