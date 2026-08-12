import type { MockHandlers } from "./index";

const delay = (ms = 250) => new Promise((r) => setTimeout(r, ms));

/**
 * Browser-only sample data for the onboarding surface. The settings-shaped
 * reads/writes (settings.snapshot, secrets.save, routes.set, models.list,
 * transcription.*, integrations.checkAll, …) already fall through to the
 * shared settings mock in lib/mock.ts — this file only covers the methods
 * that are onboarding's own.
 */
export const onboardingMocks: MockHandlers = {
  "onboarding.requestMicrophone": async () => {
    await delay(400);
    return { granted: true }; // a clean "just approved it" screenshot
  },
  "onboarding.openMicrophoneSettings": async () => {
    await delay();
    return {};
  },
  "onboarding.setBaseline": async () => {
    await delay(80);
    return {};
  },
  "onboarding.resetTrustDefaults": async () => {
    await delay(150);
    return {};
  },
  "onboarding.finish": async () => {
    await delay(150);
    return {};
  },
};
