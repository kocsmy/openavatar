import * as React from "react";
import { bridge } from "@/lib/bridge";
import type { LLMTask, ModelInfo, ProviderID, RouteTestResult, UsageRow } from "@/lib/types";
import {
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

const TASKS: { task: LLMTask; label: string }[] = [
  { task: "detection", label: "Decision detection" },
  { task: "planning", label: "Action planning & code edits" },
  { task: "summary", label: "Summaries" },
];

const PROVIDERS: { id: ProviderID; label: string }[] = [
  { id: "anthropic", label: "Anthropic" },
  { id: "openai", label: "OpenAI (or compatible)" },
  { id: "gemini", label: "Google Gemini" },
  { id: "ollama", label: "Ollama (local)" },
];

const NONE = "__none__";

function compact(tokens: number): string {
  if (tokens < 1_000) return `${tokens}`;
  if (tokens < 1_000_000) return `${(tokens / 1_000).toFixed(1)}k`;
  return `${(tokens / 1_000_000).toFixed(1)}M`;
}

export function ModelsPage() {
  const { snap, set, markSecretSaved, reload } = useSettings();
  const s = snap.settings;
  const [models, setModels] = React.useState<Partial<Record<ProviderID, ModelInfo[]>>>({});
  const [provStatus, setProvStatus] = React.useState<Partial<Record<ProviderID, { ok: boolean; text: string }>>>({});
  const [testing, setTesting] = React.useState(false);
  const [testResults, setTestResults] = React.useState<RouteTestResult[]>([]);
  const [usage, setUsage] = React.useState<UsageRow[]>([]);

  React.useEffect(() => {
    void bridge("usage.recent").then((r) => setUsage(r.rows));
    // Preload model lists for providers already routing a task.
    const used = new Set(Object.values(snap.routes).flatMap((r) => (r ? [r.provider] : [])));
    used.forEach((p) => void loadModels(p, { silent: true }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function loadModels(provider: ProviderID, opts: { silent?: boolean } = {}) {
    if (!opts.silent) setProvStatus((st) => ({ ...st, [provider]: { ok: true, text: "Checking…" } }));
    try {
      const { models: list } = await bridge("models.list", { provider });
      setModels((m) => ({ ...m, [provider]: list }));
      if (!opts.silent)
        setProvStatus((st) => ({ ...st, [provider]: { ok: true, text: `✓ ${list.length} models available` } }));
    } catch (e) {
      setProvStatus((st) => ({ ...st, [provider]: { ok: false, text: String(e) } }));
    }
  }

  async function setRoute(task: LLMTask, provider: ProviderID | null, model: string) {
    await bridge("routes.set", { task, provider, model });
    await reload();
    if (provider) void loadModels(provider, { silent: true });
  }

  return (
    <Page title="Models" description="Bring your own keys; route each task to the right model.">
      <Section
        title="Providers"
        description="BYO token — keys live in the macOS Keychain, never in the database."
      >
        {(["anthropic", "openai", "gemini"] as const).map((p) => (
          <React.Fragment key={p}>
            <Row label={PROVIDERS.find((x) => x.id === p)!.label}>
              <SecretField
                label={`${PROVIDERS.find((x) => x.id === p)!.label} API key`}
                saved={snap.secrets[p]}
                onSave={async (v) => {
                  await bridge("secrets.save", { key: p, value: v });
                  markSecretSaved(p);
                  void loadModels(p);
                }}
              />
            </Row>
            {p === "openai" && (
              <Row label="OpenAI-compatible base URL">
                <TextSetting value={s.openAIBaseURL} onCommit={(v) => set("openAIBaseURL", v)} />
              </Row>
            )}
            {provStatus[p] && <Status ok={provStatus[p]!.ok}>{provStatus[p]!.text}</Status>}
          </React.Fragment>
        ))}
        <Row label="Ollama (local, no key)">
          <TextSetting value={s.ollamaBaseURL} onCommit={(v) => set("ollamaBaseURL", v)} />
          <Button variant="outline" onClick={() => void loadModels("ollama")}>
            Check
          </Button>
        </Row>
        {provStatus.ollama && <Status ok={provStatus.ollama.ok}>{provStatus.ollama.text}</Status>}
      </Section>

      <Section
        title="Per-task routing"
        description="Route cheap/fast models to detection and summaries, a strong model to planning and code edits. Models are listed live from each provider — nothing is hard-coded."
      >
        {TASKS.map(({ task, label }) => {
          const route = snap.routes[task];
          const list = route ? (models[route.provider] ?? []) : [];
          const listHasCurrent = route?.model && list.some((m) => m.id === route.model);
          return (
            <Row key={task} label={label}>
              <Select
                value={route?.provider ?? NONE}
                onValueChange={(v) => {
                  const provider = v === NONE ? null : (v as ProviderID);
                  const keepModel = provider && route?.provider === provider ? (route?.model ?? "") : "";
                  void setRoute(task, provider, keepModel);
                }}
              >
                <SelectTrigger className="w-44 shrink-0">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={NONE}>—</SelectItem>
                  {PROVIDERS.map((p) => (
                    <SelectItem key={p.id} value={p.id}>
                      {p.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Select
                value={route?.model || NONE}
                disabled={!route}
                onValueChange={(v) => {
                  if (route) void setRoute(task, route.provider, v === NONE ? "" : v);
                }}
              >
                <SelectTrigger className="min-w-0 flex-1">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={NONE}>—</SelectItem>
                  {list.map((m) => (
                    <SelectItem key={m.id} value={m.id}>
                      {m.displayName}
                    </SelectItem>
                  ))}
                  {route?.model && !listHasCurrent ? (
                    <SelectItem value={route.model}>{route.model}</SelectItem>
                  ) : null}
                </SelectContent>
              </Select>
            </Row>
          );
        })}
      </Section>

      <Section
        title="Verify"
        description="If a call fails mid-call, the full API error appears here and in the menu-bar popover — no more truncated messages."
      >
        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            disabled={testing}
            onClick={async () => {
              setTesting(true);
              setTestResults([]);
              try {
                const { results } = await bridge("routes.test");
                setTestResults(results);
              } finally {
                setTesting(false);
              }
            }}
          >
            Send test message through each route
          </Button>
          {testing && <Spinner />}
        </div>
        {testResults.map((r) => (
          <div key={r.task} className="flex flex-col gap-0.5">
            <span className="text-xs font-semibold">
              {TASKS.find((t) => t.task === r.task)?.label ?? r.task}
            </span>
            <Status ok={r.ok} mono>
              {r.message}
            </Status>
          </div>
        ))}
      </Section>

      <Section title="Usage — last 7 days">
        {usage.length === 0 ? (
          <Hint>No LLM calls recorded yet.</Hint>
        ) : (
          <div className="flex flex-col gap-1.5">
            {usage.map((row) => (
              <div key={row.task} className="flex items-baseline justify-between gap-3">
                <span className="text-[13px]">{row.displayName}</span>
                <span className="text-xs tabular-nums text-muted-foreground">
                  {row.calls} calls · {compact(row.inputTokens)} in · {compact(row.outputTokens)} out
                  {row.cacheReadTokens > 0 ? ` · ${compact(row.cacheReadTokens)} cached` : ""}
                </span>
              </div>
            ))}
            <Hint>
              Cached input bills at roughly a tenth of the normal price (Anthropic reports it
              explicitly; OpenAI and Gemini cache long stable prefixes automatically without
              reporting).
            </Hint>
          </div>
        )}
      </Section>
    </Page>
  );
}
