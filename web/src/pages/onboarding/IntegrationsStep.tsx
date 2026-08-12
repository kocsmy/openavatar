import * as React from "react";
import { Check, Puzzle, X } from "lucide-react";
import { bridge } from "@/lib/bridge";
import type { HealthResult, SecretKey } from "@/lib/types";
import { SecretField, TextSetting, useSettings } from "@/components/shared";
import { StepBody, StepHeader } from "./shared";

const TOKENS: { key: SecretKey; id: string; label: string }[] = [
  { key: "github", id: "github", label: "GitHub fine-grained PAT" },
  { key: "slack", id: "slack", label: "Slack user token (xoxp-…)" },
  { key: "linear", id: "linear", label: "Linear API key (lin_api_…)" },
];

/** Step 5 — matches IntegrationsStep in OnboardingView.swift. */
export function IntegrationsStep() {
  const { snap, set, markSecretSaved } = useSettings();
  const [health, setHealth] = React.useState<Record<string, HealthResult>>({});

  const connect = async (key: SecretKey, value: string) => {
    await bridge("secrets.save", { key, value });
    markSecretSaved(key);
    const { results } = await bridge("integrations.checkAll");
    setHealth(Object.fromEntries(results.map((r) => [r.id, r])));
  };

  return (
    <>
      <StepHeader
        icon={Puzzle}
        title="Connect your tools"
        subtitle="Connect at least one now — the rest any time in Settings. Email setup lives in Settings → Integrations."
      />
      <StepBody className="gap-3">
        {TOKENS.map((t) => (
          <div key={t.key} className="flex flex-col gap-1.5">
            <div className="flex items-center gap-2">
              <SecretField label={t.label} saved={snap.secrets[t.key]} onSave={(v) => connect(t.key, v)} />
              {health[t.id] ? (
                health[t.id].ok ? (
                  <Check className="size-4 shrink-0 text-success" aria-label={health[t.id].message} />
                ) : (
                  <X className="size-4 shrink-0 text-destructive" aria-label={health[t.id].message} />
                )
              ) : null}
            </div>
            {t.id === "github" && (
              <TextSetting
                value={snap.settings.githubDefaultRepo}
                placeholder="Default repo (owner/name)"
                onCommit={(v) => set("githubDefaultRepo", v)}
                className="h-7 text-xs"
              />
            )}
          </div>
        ))}
      </StepBody>
    </>
  );
}
