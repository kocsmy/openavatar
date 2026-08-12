import * as React from "react";
import { Check, Hand, Lock, ShieldCheck, UserX, Zap } from "lucide-react";
import { bridge } from "@/lib/bridge";
import { useSettings } from "@/components/shared";
import { Button } from "@/components/ui/button";
import { StepBody, StepHeader } from "./shared";

/** Step 7 — matches TrustStep in OnboardingView.swift. */
export function TrustStep() {
  const { snap } = useSettings();
  const name = snap.settings.assistantName;
  const [justReset, setJustReset] = React.useState(false);

  const rows = [
    { icon: Zap, text: `PR comments and Linear tickets: autonomous when you address ${name} directly` },
    { icon: Hand, text: "Everything else: preview → your approval → executed" },
    { icon: Lock, text: "Merges and emails: locked to Ask-first until 10 clean approvals" },
    { icon: UserX, text: "Requests spoken by other participants: never destructive without you" },
  ];

  return (
    <>
      <StepHeader
        icon={ShieldCheck}
        title="Safe defaults"
        subtitle="Everything asks first, except two low-risk actions in Active mode. Adjust the full matrix any time in Settings → Trust."
      />
      <StepBody className="items-center gap-5">
        <div className="flex w-full flex-col gap-2.5">
          {rows.map((r, i) => (
            <div key={i} className="flex items-start gap-2.5 text-[13px]">
              <r.icon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
              <span>{r.text}</span>
            </div>
          ))}
        </div>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            onClick={async () => {
              await bridge("onboarding.resetTrustDefaults");
              setJustReset(true);
              setTimeout(() => setJustReset(false), 2000);
            }}
          >
            Reset to these defaults
          </Button>
          {justReset && (
            <span className="flex items-center gap-1 text-xs text-success">
              <Check className="size-3.5" /> Reset
            </span>
          )}
        </div>
      </StepBody>
    </>
  );
}
