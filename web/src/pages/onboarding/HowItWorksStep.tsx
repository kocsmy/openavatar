import { Inbox, ShieldCheck, SlidersHorizontal, Zap } from "lucide-react";
import { useSettings } from "@/components/shared";
import { FeatureRow, StepBody, StepHeader } from "./shared";

/** Step 1 — matches HowItWorksStep in OnboardingView.swift. */
export function HowItWorksStep() {
  const { snap } = useSettings();
  const name = snap.settings.assistantName;
  return (
    <>
      <StepHeader
        icon={SlidersHorizontal}
        title="You stay in control"
        subtitle="Two modes, one trust ladder. Nothing destructive happens without you."
      />
      <StepBody className="gap-[18px]">
        <FeatureRow
          icon={Inbox}
          title="Passive mode (default)"
          detail="Decisions pile up quietly during the call. When it ends, you get a review sheet: Approve, Edit, or Dismiss each one. Approved items are executed by the app immediately."
        />
        <FeatureRow
          icon={Zap}
          title="Active mode"
          detail={`Say “${name}, open a ticket for that” mid-call and it happens right away — for action types you've marked Autonomous.`}
        />
        <FeatureRow
          icon={ShieldCheck}
          title="The trust ladder"
          detail="Every action type starts as Ask-first. Risky actions (merging PRs, sending email) can only go Autonomous after 10 approvals without a single revert or edit. One-click Undo everywhere it's possible."
        />
      </StepBody>
    </>
  );
}
