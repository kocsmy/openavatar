import * as React from "react";
import { Cpu, TriangleAlert } from "lucide-react";
import { bridge } from "@/lib/bridge";
import type { TranscriptionMode, TranscriptionStatus } from "@/lib/types";
import { SecretField, TextSetting, useSettings } from "@/components/shared";
import { Button } from "@/components/ui/button";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Label } from "@/components/ui/label";
import { StepBody, StepHeader } from "./shared";

const MODES: { id: TranscriptionMode; label: string }[] = [
  { id: "local", label: "Whisper (offline, 99 languages)" },
  { id: "parakeet", label: "Parakeet (offline, fastest — 25 languages)" },
  { id: "qwen", label: "Qwen3-ASR (offline, most accurate — 52 languages)" },
  { id: "cloud", label: "Cloud (BYO key)" },
];

/** Step 3 — matches TranscriptionStep in OnboardingView.swift. */
export function TranscriptionStep() {
  const { snap, set } = useSettings();
  const s = snap.settings;

  return (
    <>
      <StepHeader
        icon={Cpu}
        title="How should calls be transcribed?"
        subtitle="Local keeps audio on this Mac. Cloud is more accurate on noisy calls but sends audio to your provider."
      />
      <StepBody className="gap-4">
        <RadioGroup
          value={s.transcriptionMode}
          onValueChange={(v) => set("transcriptionMode", v as TranscriptionMode)}
          className="gap-2.5"
        >
          {MODES.map((m) => (
            <label key={m.id} className="flex cursor-pointer items-center gap-2.5 text-[13.5px]">
              <RadioGroupItem value={m.id} />
              {m.label}
            </label>
          ))}
        </RadioGroup>

        {s.transcriptionMode === "local" && <WhisperSetupCard />}

        {s.transcriptionMode === "qwen" && (
          <InfoCard>
            The most accurate local option (52 languages, including Hungarian) — needs a one-time setup
            in Settings → Transcription after onboarding: a small Python runtime plus ~3.4 GB of model
            weights, fully offline afterwards.
          </InfoCard>
        )}

        {s.transcriptionMode === "parakeet" && (
          <InfoCard>
            Fully on-device, like Whisper — ~600 MB of neural models download automatically on your
            first call (or from Settings → Transcription). Fastest and most accurate for English,
            Hungarian, and 23 more languages.
          </InfoCard>
        )}

        {s.transcriptionMode === "cloud" && (
          <div className="flex flex-col gap-3 rounded-lg border border-border p-3.5">
            <Label className="flex items-center gap-2 text-[13px] font-normal text-warning">
              <TriangleAlert className="size-4 shrink-0" />
              Call audio will be sent to the provider below.
            </Label>
            <TextSetting
              value={s.cloudSTTBaseURL}
              placeholder="Base URL"
              onCommit={(v) => set("cloudSTTBaseURL", v)}
            />
            <SecretField
              label="API key"
              saved={snap.secrets.cloudSTT}
              onSave={async (v) => {
                await bridge("secrets.save", { key: "cloudSTT", value: v });
              }}
            />
          </div>
        )}
      </StepBody>
    </>
  );
}

function InfoCard({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex items-start gap-2.5 rounded-lg border border-border p-3.5">
      <Cpu className="mt-0.5 size-4 shrink-0 text-primary" />
      <p className="text-[13px] leading-relaxed">{children}</p>
    </div>
  );
}

/**
 * Condensed port of WhisperSetupView (SettingsView.swift) — same copy, same
 * two actions, without the quality picker and CLI/model paths that only
 * belong in the full Settings tab (the native onboarding step omits them too).
 */
function WhisperSetupCard() {
  const [status, setStatus] = React.useState<TranscriptionStatus | null>(null);

  React.useEffect(() => {
    let alive = true;
    const tick = async () => {
      const st = await bridge("transcription.status");
      if (alive) setStatus(st);
    };
    void tick();
    const id = setInterval(tick, 2000);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, []);

  const w = status?.whisper;
  const busy = w?.phase === "busy";

  return (
    <div className="flex flex-col gap-2 rounded-lg border border-border p-3.5">
      <div className="flex items-center justify-between gap-3">
        <p className="text-[13px]">
          {w?.ready
            ? "Local transcription is ready."
            : "One click installs whisper.cpp (via Homebrew) and downloads the multilingual base model (~150 MB)."}
        </p>
        <Button
          size="sm"
          disabled={busy}
          onClick={() => void bridge("transcription.setupWhisper", {})}
        >
          {w?.ready ? "Re-check" : "Set up automatically"}
        </Button>
      </div>
      {w?.phase === "busy" && <p className="text-xs text-muted-foreground">{w.message || "Working…"}</p>}
      {w?.phase === "done" && <p className="text-xs text-success">{w.message}</p>}
      {w?.phase === "failed" && <p className="text-xs text-destructive">{w.message}</p>}
    </div>
  );
}
