import * as React from "react";
import { AudioWaveform, TrendingUp } from "lucide-react";
import { bridge } from "@/lib/bridge";
import { useSettings } from "@/components/shared";
import { Slider } from "@/components/ui/slider";
import { StepBody, StepHeader } from "./shared";

/** Step 8 — matches BaselineAndFinishStep in OnboardingView.swift (PRD §7). */
export function BaselineAndFinishStep() {
  const { snap } = useSettings();
  // Starts at 30, same as the native step — it doesn't read back a prior
  // baseline either (settings.snapshot doesn't carry adminMinutesBaseline).
  const [minutes, setMinutes] = React.useState(30);

  return (
    <>
      <StepHeader
        icon={TrendingUp}
        title="One last thing"
        subtitle="So the metrics dashboard can show what you're saving:"
      />
      <StepBody className="gap-6">
        <div className="flex flex-col items-center gap-3">
          <p className="text-center text-[13px] text-muted-foreground">
            Roughly how many minutes per day do you spend routing post-call tasks — filing tickets,
            pinging people, writing follow-up emails?
          </p>
          <div className="flex w-full items-center gap-3">
            <Slider
              value={[minutes]}
              min={0}
              max={180}
              step={5}
              onValueChange={([v]) => setMinutes(v)}
              onValueCommit={([v]) => void bridge("onboarding.setBaseline", { minutes: v })}
            />
            <span className="w-16 shrink-0 text-right text-[13px] tabular-nums">{minutes} min</span>
          </div>
        </div>

        <div className="flex flex-col gap-1.5 rounded-lg border border-border p-3.5">
          <span className="text-[13px] font-semibold">Try it now</span>
          <p className="text-[13px] leading-relaxed text-muted-foreground">
            Click the <AudioWaveform className="mx-0.5 inline size-3.5 -translate-y-px text-primary" /> icon
            in your menu bar, press Listen, and say: “{snap.settings.assistantName}, create a ticket to
            test my setup.” Then approve it from the popover.
          </p>
        </div>
      </StepBody>
    </>
  );
}
