import * as React from "react";
import { bridge } from "@/lib/bridge";
import type { TranscriptionMode, TranscriptionStatus } from "@/lib/types";
import {
  Chip,
  Hint,
  Page,
  Row,
  SecretField,
  Section,
  Spinner,
  Status,
  TextSetting,
  useSettings,
} from "@/components/shared";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";

const WHISPER_MODELS = [
  { id: "base", label: "Base — fastest, okay accuracy (~150 MB)" },
  { id: "small", label: "Small — much better accuracy (~500 MB)" },
  { id: "medium", label: "Medium — near-best, slower (~1.5 GB)" },
  { id: "largeTurbo", label: "Large v3 Turbo — best, needs a fast Mac (~1.6 GB)" },
];

const MODEL_FILE_TO_ID: Record<string, string> = {
  "ggml-base.bin": "base",
  "ggml-small.bin": "small",
  "ggml-medium.bin": "medium",
  "ggml-large-v3-turbo.bin": "largeTurbo",
};

export function TranscriptionPage() {
  const { snap, set } = useSettings();
  const s = snap.settings;
  const [status, setStatus] = React.useState<TranscriptionStatus | null>(null);

  // Setup runs in the host; poll while the page is open so progress shows up.
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

  const engines: {
    mode: TranscriptionMode;
    title: string;
    specs: string;
    guidance: string;
    chip: { tone: "success" | "warning" | "destructive" | "muted"; text: string };
  }[] = [
    {
      mode: "parakeet",
      title: "Parakeet V3",
      specs: "5× faster · Most accurate · 25 languages · On-device · ~600 MB",
      guidance:
        "Recommended for most calls — English, Hungarian, and most European languages, on the Neural Engine, fully offline.",
      chip: parakeetChip(status),
    },
    {
      mode: "local",
      title: "Whisper",
      specs: "1× speed · 99 languages · On-device · 150 MB – 1.6 GB",
      guidance:
        "Use for languages outside Parakeet's 25 — the widest coverage there is. Pick the model quality below.",
      chip: status?.whisper.ready
        ? { tone: "success", text: "Installed" }
        : { tone: "warning", text: "Setup needed" },
    },
    {
      mode: "qwen",
      title: "Qwen3-ASR 1.7B",
      specs: "Most accurate · 52 languages · On-device (MLX) · ~3.4 GB",
      guidance:
        "The strongest open transcription model that runs locally — includes Hungarian. Needs a one-time setup (Python runtime + big download) and ~4 GB of memory while active.",
      chip: qwenChip(status),
    },
    {
      mode: "cloud",
      title: "Cloud",
      specs: "Provider-dependent · Bring your own key · Audio leaves your Mac",
      guidance:
        "Use only if you specifically want a cloud provider's engine — the on-device options keep calls private.",
      chip: snap.secrets.cloudSTT
        ? { tone: "success", text: "Key saved" }
        : { tone: "muted", text: "BYO key" },
    },
  ];

  const activeWhisperModel = MODEL_FILE_TO_ID[
    Object.keys(MODEL_FILE_TO_ID).find((f) => s.whisperModelPath.endsWith(f)) ?? ""
  ];

  return (
    <Page title="Transcription" description="Which engine hears your calls, and how.">
      <Section title="Engine">
        <div className="flex flex-col gap-2">
          {engines.map((e) => (
            <button
              key={e.mode}
              onClick={() => set("transcriptionMode", e.mode)}
              className={cn(
                "rounded-lg border p-3 text-left transition-colors",
                s.transcriptionMode === e.mode
                  ? "border-primary bg-primary/6 ring-1 ring-primary"
                  : "border-border hover:bg-accent/40",
              )}
            >
              <div className="flex items-start gap-2.5">
                <span
                  className={cn(
                    "mt-0.5 size-3.5 rounded-full border-[5px]",
                    s.transcriptionMode === e.mode
                      ? "border-primary bg-white"
                      : "border-input bg-card",
                  )}
                />
                <div className="flex min-w-0 flex-col gap-0.5">
                  <div className="flex items-center gap-2">
                    <span className="text-[13px] font-semibold">{e.title}</span>
                    <Chip tone={e.chip.tone}>{e.chip.text}</Chip>
                  </div>
                  <span className="text-xs text-muted-foreground">{e.specs}</span>
                  <span className="text-xs text-muted-foreground/70">{e.guidance}</span>
                </div>
              </div>
            </button>
          ))}
        </div>
      </Section>

      {s.transcriptionMode === "parakeet" && <ParakeetSetup status={status} />}
      {s.transcriptionMode === "local" && (
        <WhisperSetup status={status} activeModel={activeWhisperModel} />
      )}
      {s.transcriptionMode === "qwen" && <QwenSetup status={status} />}
      {s.transcriptionMode === "cloud" && <CloudSetup />}

      {s.transcriptionMode !== "parakeet" && s.transcriptionMode !== "qwen" && (
        <>
          <Section title="Language">
            <Row
              label="Spoken language"
              hint="Auto-detect handles multilingual calls (e.g. mixing Hungarian and English). Local mode needs the multilingual model — the auto-setup above installs it."
            >
              <Select
                value={s.transcriptionLanguage}
                onValueChange={(v) => set("transcriptionLanguage", v)}
              >
                <SelectTrigger className="max-w-64">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {snap.languages.map((l) => (
                    <SelectItem key={l.code} value={l.code}>
                      {l.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Row>
          </Section>
          <Section title="Custom vocabulary">
            <Textarea
              placeholder="PostHog, Termly, Linear…"
              defaultValue={s.customVocabulary}
              onBlur={(e) => {
                if (e.target.value !== s.customVocabulary) set("customVocabulary", e.target.value);
              }}
            />
            <Hint>
              Type words comma-separated and transcription is biased toward spelling them correctly.
              Speaker names and calendar attendees are added automatically on each call.
            </Hint>
          </Section>
        </>
      )}

      <Section title="Speakers">
        <Row
          label="Distinguish individual speakers"
          hint='Neural voice fingerprints (CoreML, on-device) label each participant on the call — your own mic is always "You". The models (~tens of MB) download automatically on your first call and run fully offline. Names you assign carry across calls.'
        >
          <Switch checked={s.diarizationEnabled} onCheckedChange={(v) => set("diarizationEnabled", v)} />
        </Row>
      </Section>
    </Page>
  );
}

function parakeetChip(status: TranscriptionStatus | null): {
  tone: "success" | "warning" | "destructive" | "muted";
  text: string;
} {
  switch (status?.parakeet.state) {
    case "ready":
      return { tone: "success", text: "Ready" };
    case "preparing":
      return { tone: "warning", text: "Downloading…" };
    case "failed":
      return { tone: "destructive", text: "Setup failed" };
    default:
      return { tone: "muted", text: "600 MB download" };
  }
}

function qwenChip(status: TranscriptionStatus | null): {
  tone: "success" | "warning" | "destructive" | "muted";
  text: string;
} {
  if (!status) return { tone: "muted", text: "…" };
  if (status.qwen.phase === "done") return { tone: "success", text: "Ready" };
  if (status.qwen.phase === "busy") return { tone: "warning", text: "Setting up…" };
  if (status.qwen.runtimeInstalled) return { tone: "success", text: "Installed" };
  return { tone: "warning", text: "Setup needed" };
}

function ParakeetSetup({ status }: { status: TranscriptionStatus | null }) {
  const state = status?.parakeet.state ?? "idle";
  return (
    <Section title="Parakeet setup">
      {state === "ready" && (
        <Status ok>
          Parakeet is ready to go — models are on this Mac; transcription runs on the Neural Engine,
          fully offline.
        </Status>
      )}
      {state === "preparing" && (
        <div className="flex items-center gap-2">
          <Spinner />
          <Status>Downloading &amp; loading models (~600 MB, one-time)…</Status>
        </div>
      )}
      {state === "failed" && (
        <>
          <Status ok={false} mono>
            {status?.parakeet.message}
          </Status>
          <div>
            <Button variant="outline" onClick={() => void bridge("transcription.prepareParakeet")}>
              Retry
            </Button>
          </div>
        </>
      )}
      {state === "idle" && (
        <div className="flex items-center gap-3">
          <Button onClick={() => void bridge("transcription.prepareParakeet")}>
            Download &amp; prepare
          </Button>
          <Hint>~600 MB, one-time — stored on this Mac; everything runs offline afterwards.</Hint>
        </div>
      )}
      <Hint>
        Language is detected automatically among Parakeet's 25. For calls in languages outside that
        set, switch to Whisper — it covers 99.
      </Hint>
    </Section>
  );
}

function WhisperSetup({
  status,
  activeModel,
}: {
  status: TranscriptionStatus | null;
  activeModel: string | undefined;
}) {
  const { snap, set } = useSettings();
  const s = snap.settings;
  const w = status?.whisper;
  const busy = w?.phase === "busy";
  return (
    <Section title="Whisper setup">
      <div className="flex items-center justify-between gap-3">
        <Status ok={w?.ready ? true : undefined}>
          {w?.ready
            ? "Local transcription is ready."
            : "One click installs whisper.cpp (via Homebrew) and downloads the multilingual base model (~150 MB)."}
        </Status>
        <Button
          disabled={busy}
          variant={w?.ready ? "outline" : "default"}
          onClick={() => void bridge("transcription.setupWhisper", {})}
        >
          {w?.ready ? "Re-check" : "Set up automatically"}
        </Button>
      </div>
      {busy && (
        <div className="flex items-center gap-2">
          <Spinner />
          <Status>{w?.message || "Working…"}</Status>
        </div>
      )}
      {w?.phase === "done" && <Status ok>{w.message}</Status>}
      {w?.phase === "failed" && (
        <Status ok={false} mono>
          {w.message}
        </Status>
      )}
      <Row
        label="Transcription quality"
        hint="Bigger models transcribe noticeably better, especially with accents, names, and crosstalk — Small is the sweet spot for most Macs; Large v3 Turbo is the best that still keeps up live. Switching applies immediately (first use of a model downloads it once)."
      >
        <Select
          value={activeModel ?? "base"}
          disabled={busy}
          onValueChange={(v) => void bridge("transcription.setupWhisper", { model: v })}
        >
          <SelectTrigger className="max-w-80">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {WHISPER_MODELS.map((m) => (
              <SelectItem key={m.id} value={m.id}>
                {m.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </Row>
      {!w?.ready && (
        <>
          <Row label="whisper-cli path">
            <TextSetting value={s.whisperCLIPath} onCommit={(v) => set("whisperCLIPath", v)} />
          </Row>
          <Row label="Model path (.bin)">
            <TextSetting value={s.whisperModelPath} onCommit={(v) => set("whisperModelPath", v)} />
          </Row>
        </>
      )}
    </Section>
  );
}

function QwenSetup({ status }: { status: TranscriptionStatus | null }) {
  const q = status?.qwen;
  return (
    <Section title="Qwen3-ASR setup">
      {q?.phase === "done" && <Status ok>{q.message}</Status>}
      {q?.phase === "busy" && (
        <div className="flex items-center gap-2">
          <Spinner />
          <Status>{q.message || "Setting up…"}</Status>
        </div>
      )}
      {q?.phase === "failed" && (
        <>
          <Status ok={false} mono>
            {q.message}
          </Status>
          <div>
            <Button variant="outline" onClick={() => void bridge("transcription.setupQwen")}>
              Retry
            </Button>
          </div>
        </>
      )}
      {(!q || q.phase === "idle") && (
        <div className="flex items-center gap-3">
          <Button onClick={() => void bridge("transcription.setupQwen")}>
            {q?.runtimeInstalled ? "Load model" : "Set up & download"}
          </Button>
          <Hint>
            {q?.runtimeInstalled
              ? "Runtime installed — this loads the model into memory (downloads it first if missing)."
              : "One-time: installs uv (via Homebrew) and the MLX bridge, then downloads ~3.4 GB of model weights. Fully offline afterwards."}
          </Hint>
        </div>
      )}
      <Hint>
        Language is detected automatically among Qwen3-ASR's 52 (including Hungarian). The model uses
        ~4 GB of memory while transcription is active.
      </Hint>
    </Section>
  );
}

function CloudSetup() {
  const { snap, set, markSecretSaved } = useSettings();
  const s = snap.settings;
  return (
    <Section title="Cloud STT (OpenAI-compatible, BYO key)">
      <Row label="Base URL">
        <TextSetting value={s.cloudSTTBaseURL} onCommit={(v) => set("cloudSTTBaseURL", v)} />
      </Row>
      <Row label="Model">
        <TextSetting value={s.cloudSTTModel} onCommit={(v) => set("cloudSTTModel", v)} />
      </Row>
      <Row label="API key">
        <SecretField
          label="API key"
          saved={snap.secrets.cloudSTT}
          onSave={async (v) => {
            await bridge("secrets.save", { key: "cloudSTT", value: v });
            markSecretSaved("cloudSTT");
          }}
        />
      </Row>
      <Hint>
        Any OpenAI-compatible transcription endpoint works (override the base URL for Deepgram/Groq-style
        services).
      </Hint>
    </Section>
  );
}
