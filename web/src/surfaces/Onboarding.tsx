import * as React from "react";
import { bridge } from "@/lib/bridge";
import { SettingsProvider, useSettings } from "@/components/shared";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { WelcomeStep } from "@/pages/onboarding/WelcomeStep";
import { HowItWorksStep } from "@/pages/onboarding/HowItWorksStep";
import { PermissionsStep } from "@/pages/onboarding/PermissionsStep";
import { TranscriptionStep } from "@/pages/onboarding/TranscriptionStep";
import { LLMStep } from "@/pages/onboarding/LLMStep";
import { IntegrationsStep } from "@/pages/onboarding/IntegrationsStep";
import { IdentityStep } from "@/pages/onboarding/IdentityStep";
import { TrustStep } from "@/pages/onboarding/TrustStep";
import { BaselineAndFinishStep } from "@/pages/onboarding/BaselineAndFinishStep";

const STEPS = [
  WelcomeStep,
  HowItWorksStep,
  PermissionsStep,
  TranscriptionStep,
  LLMStep,
  IntegrationsStep,
  IdentityStep,
  TrustStep,
  BaselineAndFinishStep,
] as const;

/**
 * First-run onboarding wizard (spec §4.10) — one concept per screen,
 * permission priming before the system prompt, live validation of keys and
 * integrations, a "try it" moment at the end. Every step is skippable.
 * Direct port of OnboardingView.swift; the shell (steps, dots, footer) lives
 * here, one component per step under pages/onboarding/.
 */
export default function OnboardingSurface() {
  return (
    <SettingsProvider>
      <Wizard />
    </SettingsProvider>
  );
}

function Wizard() {
  const { snap } = useSettings();
  const [step, setStep] = React.useState(0);
  const Step = STEPS[step];
  const isLast = step === STEPS.length - 1;

  const finish = async () => {
    await bridge("onboarding.finish");
    await bridge("window.close", {});
  };

  return (
    <div className="flex h-screen flex-col bg-background">
      <div className="flex flex-1 items-center justify-center overflow-y-auto px-12 py-9">
        <div className="w-full max-w-xl">
          <Step />
        </div>
      </div>

      <div className="flex items-center gap-3 border-t border-border px-6 py-4">
        <Button variant="ghost" disabled={step === 0} onClick={() => setStep((s) => Math.max(0, s - 1))}>
          Back
        </Button>
        <div className="flex flex-1 items-center justify-center gap-1.5">
          {STEPS.map((_, i) => (
            <span
              key={i}
              className={cn("size-1.5 rounded-full", i === step ? "bg-primary" : "bg-muted-foreground/25")}
            />
          ))}
        </div>
        {isLast ? (
          <Button onClick={() => void finish()}>Start using {snap.settings.assistantName}</Button>
        ) : (
          <>
            <Button variant="ghost" onClick={() => setStep((s) => s + 1)}>
              Skip
            </Button>
            <Button onClick={() => setStep((s) => s + 1)}>Continue</Button>
          </>
        )}
      </div>
    </div>
  );
}
