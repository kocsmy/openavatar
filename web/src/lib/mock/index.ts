import { homeMocks } from "./home";
import { metricsMocks } from "./metrics";
import { meetingsMocks } from "./meetings";
import { followupsMocks } from "./followups";
import { callMocks } from "./call";
import { onboardingMocks } from "./onboarding";
import { menuMocks } from "./menu";

/**
 * Per-surface browser stand-ins, keyed by bridge method name. One file per
 * surface so the mocks stay next to the page that needs them.
 */
export type MockHandlers = Record<
  string,
  (params: Record<string, unknown>) => unknown | Promise<unknown>
>;

export const mockHandlers: MockHandlers = {
  ...homeMocks,
  ...metricsMocks,
  ...meetingsMocks,
  ...followupsMocks,
  ...callMocks,
  ...onboardingMocks,
  ...menuMocks,
  "ui.resize": () => ({}),
};

/** Small helper so mock data can feel like it travelled somewhere. */
export const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
