import * as React from "react";
import { Mic, Volume2 } from "lucide-react";
import { bridge } from "@/lib/bridge";
import { Button } from "@/components/ui/button";
import { FeatureRow, StepBody, StepHeader } from "./shared";

/**
 * Step 2 — matches PermissionsStep in OnboardingView.swift. Only the
 * microphone is requested explicitly; system audio is captured the first
 * time a call starts, so macOS prompts for it then, not here (same as the
 * native step — there is no second button).
 */
export function PermissionsStep() {
  const [micGranted, setMicGranted] = React.useState<boolean | null>(null);

  const requestMic = async () => {
    if (micGranted === false) {
      void bridge("onboarding.openMicrophoneSettings");
      return;
    }
    const { granted } = await bridge("onboarding.requestMicrophone");
    setMicGranted(granted);
  };

  const buttonLabel =
    micGranted === true ? "Granted ✓" : micGranted === false ? "Open System Settings" : "Allow microphone";

  return (
    <>
      <StepHeader
        icon={Mic}
        title="Two permissions, both local"
        subtitle="Audio is processed on this Mac. The menu-bar icon always shows when recording is on, and ⌘⇧L stops it instantly."
      />
      <StepBody className="gap-[18px]">
        <div className="flex items-start justify-between gap-4">
          <FeatureRow icon={Mic} title="Microphone" detail="Your side of the conversation." />
          <Button className="shrink-0" disabled={micGranted === true} onClick={() => void requestMic()}>
            {buttonLabel}
          </Button>
        </div>
        <FeatureRow
          icon={Volume2}
          title="System audio"
          detail="The other participants. macOS will ask the first time you start listening during a call — approve “Audio Recording” when prompted."
        />
      </StepBody>
    </>
  );
}
