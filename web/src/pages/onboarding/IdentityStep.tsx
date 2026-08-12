import { UserRound } from "lucide-react";
import { TextSetting, useSettings } from "@/components/shared";
import { Input } from "@/components/ui/input";
import { StepBody, StepHeader } from "./shared";

/** Step 6 — matches IdentityStep in OnboardingView.swift. */
export function IdentityStep() {
  const { snap, set } = useSettings();
  const name = snap.settings.assistantName;

  return (
    <>
      <StepHeader
        icon={UserRound}
        title="Name your assistant"
        subtitle="The name is also the wake phrase in Active mode."
      />
      <StepBody className="gap-3">
        {/* Live-bound (not the usual commit-on-blur TextSetting) — the
            wake-phrase preview below needs to track every keystroke, same as
            the native TextField's direct binding to settings.assistantName. */}
        <Input
          className="text-center text-lg"
          value={name}
          onChange={(e) => set("assistantName", e.target.value)}
        />
        <p className="text-center text-[13px] text-muted-foreground">
          On a call you'll say: “{name}, create a ticket for the login bug.”
        </p>
        <TextSetting
          value={snap.settings.userDisplayName}
          placeholder="Your name (shown in email attribution)"
          onCommit={(v) => set("userDisplayName", v)}
        />
      </StepBody>
    </>
  );
}
