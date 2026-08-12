import { AudioWaveform, Ear, Sparkles, Zap } from "lucide-react";
import { useSettings } from "@/components/shared";
import { FeatureRow, StepBody, StepHeader } from "./shared";

/** Step 0 — matches WelcomeStep in OnboardingView.swift. */
export function WelcomeStep() {
  const { snap } = useSettings();
  return (
    <>
      <StepHeader
        icon={AudioWaveform}
        title={`Meet ${snap.settings.assistantName}`}
        subtitle="Your calls end with things done — not with a to-do list."
      />
      <StepBody className="gap-[18px]">
        <FeatureRow
          icon={Ear}
          title="Listens locally to your calls"
          detail="Zoom, Meet, Slack huddles, Teams — audio is captured on this Mac. It never joins the call and nothing records unless you switch it on."
        />
        <FeatureRow
          icon={Sparkles}
          title="Detects decisions as they happen"
          detail="“Let's ship the header fix”, “File a ticket for that”, “Tell #design it's ready” — each becomes an actionable item with the exact quote."
        />
        <FeatureRow
          icon={Zap}
          title="Executes them for you"
          detail="Opens PRs, creates Linear tickets, posts to Slack, sends email — under your accounts, always marked with 🤖 so everyone knows what was automated."
        />
      </StepBody>
    </>
  );
}
