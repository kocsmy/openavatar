import * as React from "react";
import { Brain, KeyRound } from "lucide-react";
import { bridge } from "@/lib/bridge";
import type { LLMTask, ModelInfo, ProviderID, SecretKey } from "@/lib/types";
import { useSettings } from "@/components/shared";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { StepBody, StepHeader } from "./shared";

const PROVIDERS: { id: ProviderID; label: string }[] = [
  { id: "anthropic", label: "Anthropic" },
  { id: "openai", label: "OpenAI (or compatible)" },
  { id: "gemini", label: "Google Gemini" },
  { id: "ollama", label: "Ollama (local)" },
];

const TASKS: LLMTask[] = ["detection", "planning", "summary"];

const KEYCHAIN_KEY: Partial<Record<ProviderID, SecretKey>> = {
  anthropic: "anthropic",
  openai: "openai",
  gemini: "gemini",
};

/**
 * Step 4 — matches LLMStep in OnboardingView.swift. One combined action
 * (save the key, then list models) rather than the settings pages' separate
 * Save/Test buttons — that's the native step's shape, kept as-is.
 */
export function LLMStep() {
  const { snap, reload } = useSettings();
  const [provider, setProvider] = React.useState<ProviderID>("anthropic");
  const [key, setKey] = React.useState("");
  const [status, setStatus] = React.useState<{ ok: boolean; text: string } | null>(null);
  const [models, setModels] = React.useState<ModelInfo[]>([]);
  const [selectedModel, setSelectedModel] = React.useState("");

  const applyToAllTasks = async (p: ProviderID, model: string) => {
    await Promise.all(TASKS.map((task) => bridge("routes.set", { task, provider: p, model })));
    await reload();
  };

  const validate = async () => {
    const secretKey = KEYCHAIN_KEY[provider];
    if (secretKey && key) {
      await bridge("secrets.save", { key: secretKey, value: key });
    }
    setStatus({ ok: true, text: "Checking…" });
    try {
      const { models: list } = await bridge("models.list", { provider });
      setModels(list);
      if (list[0]) {
        setSelectedModel(list[0].id);
        await applyToAllTasks(provider, list[0].id);
      }
      setStatus({ ok: true, text: `✓ Key works — ${list.length} models` });
    } catch (e) {
      setStatus({ ok: false, text: e instanceof Error ? e.message : String(e) });
    }
  };

  return (
    <>
      <StepHeader
        icon={Brain}
        title="Connect a model"
        subtitle="Bring your own key — Anthropic, OpenAI, Gemini, or a local Ollama. You can route different tasks to different models later."
      />
      <StepBody className="gap-3">
        <Select value={provider} onValueChange={(v) => setProvider(v as ProviderID)}>
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {PROVIDERS.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        {provider !== "ollama" && (
          <div className="flex items-center gap-2">
            <Input
              type="password"
              autoComplete="off"
              placeholder={snap.secrets[provider] ? "API key — saved ✓ (paste to replace)" : "API key"}
              value={key}
              onChange={(e) => setKey(e.target.value)}
            />
            {snap.secrets[provider] && !key ? (
              <KeyRound className="size-3.5 shrink-0 text-success" aria-label="A key is saved" />
            ) : null}
          </div>
        )}

        <div className="flex items-center gap-3">
          <Button onClick={() => void validate()}>Validate &amp; list models</Button>
          {status && (
            <span className={`text-[13px] ${status.ok ? "text-success" : "text-warning"}`}>
              {status.text}
            </span>
          )}
        </div>

        {models.length > 0 && (
          <Select
            value={selectedModel}
            onValueChange={(v) => {
              setSelectedModel(v);
              void applyToAllTasks(provider, v);
            }}
          >
            <SelectTrigger>
              <SelectValue placeholder="Model for everything (refine later)" />
            </SelectTrigger>
            <SelectContent>
              {models.map((m) => (
                <SelectItem key={m.id} value={m.id}>
                  {m.displayName}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        )}
      </StepBody>
    </>
  );
}
