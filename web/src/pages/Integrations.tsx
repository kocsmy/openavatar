import * as React from "react";
import { bridge } from "@/lib/bridge";
import type { CalendarInfo, HealthResult, KnownIntegrations } from "@/lib/types";
import {
  ExternalLink,
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
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Switch } from "@/components/ui/switch";
import { CheckCircle2, ChevronDown, ChevronRight, Trash2, XCircle } from "lucide-react";

export function IntegrationsPage() {
  const [health, setHealth] = React.useState<Record<string, HealthResult>>({});
  const [checkingAll, setCheckingAll] = React.useState(false);
  const [known, setKnown] = React.useState<KnownIntegrations | null>(null);

  React.useEffect(() => {
    void bridge("integrations.known").then(setKnown);
  }, []);

  const check = async (id: string) => {
    const result = await bridge("integrations.check", { id });
    setHealth((h) => ({ ...h, [id]: result }));
  };

  return (
    <Page title="Integrations" description="Where detected actions get executed — all BYO tokens.">
      <GoogleCalendarSection />
      <TokenSection
        id="github"
        title="GitHub"
        description="Fine-grained PAT (repo contents + pull requests)."
        secretKey="github"
        secretLabel="Personal access token"
        health={health.github}
        onSaved={check}
        extra={<GithubDefaults />}
      />
      <TokenSection
        id="slack"
        title="Slack"
        description="User token (xoxp-)."
        secretKey="slack"
        secretLabel="User OAuth token"
        health={health.slack}
        onSaved={check}
        extra={<SlackDefaults />}
      />
      <TokenSection
        id="linear"
        title="Linear"
        description="Personal API key."
        secretKey="linear"
        secretLabel="API key (lin_api_…)"
        health={health.linear}
        onSaved={check}
        extra={<LinearDefaults />}
      />
      <EmailSection health={health.email} onSaved={check} />
      <ManifestSection known={known} health={health} onSaved={check} />
      <MCPSection known={known} setKnown={setKnown} health={health} />
      <div className="flex items-center gap-2">
        <Button
          variant="outline"
          disabled={checkingAll}
          onClick={async () => {
            setCheckingAll(true);
            try {
              const { results } = await bridge("integrations.checkAll");
              setHealth((h) => {
                const next = { ...h };
                for (const r of results) next[r.id] = r;
                return next;
              });
            } finally {
              setCheckingAll(false);
            }
          }}
        >
          Test all connections
        </Button>
        {checkingAll && <Spinner />}
      </div>
    </Page>
  );
}

function HealthLine({ health }: { health?: HealthResult }) {
  if (!health) return null;
  return (
    <div className="flex items-center gap-1.5">
      {health.ok ? (
        <CheckCircle2 className="size-3.5 shrink-0 text-success" />
      ) : (
        <XCircle className="size-3.5 shrink-0 text-destructive" />
      )}
      <Status ok={health.ok}>{health.message}</Status>
    </div>
  );
}

function TokenSection({
  id,
  title,
  description,
  secretKey,
  secretLabel,
  health,
  onSaved,
  extra,
}: {
  id: string;
  title: string;
  description: string;
  secretKey: "github" | "slack" | "linear";
  secretLabel: string;
  health?: HealthResult;
  onSaved: (id: string) => void;
  extra?: React.ReactNode;
}) {
  const { snap, markSecretSaved } = useSettings();
  return (
    <Section title={title} description={description}>
      <SecretField
        label={secretLabel}
        saved={snap.secrets[secretKey]}
        onSave={async (v) => {
          await bridge("secrets.save", { key: secretKey, value: v });
          markSecretSaved(secretKey);
          onSaved(id);
        }}
      />
      {extra}
      <HealthLine health={health} />
    </Section>
  );
}

function GithubDefaults() {
  const { snap, set } = useSettings();
  return (
    <Row label="Default repo (owner/name)">
      <TextSetting value={snap.settings.githubDefaultRepo} onCommit={(v) => set("githubDefaultRepo", v)} />
    </Row>
  );
}

function SlackDefaults() {
  const { snap, set } = useSettings();
  return (
    <Row label="Default channel (#name)">
      <TextSetting value={snap.settings.slackDefaultChannel} onCommit={(v) => set("slackDefaultChannel", v)} />
    </Row>
  );
}

function LinearDefaults() {
  const { snap, set } = useSettings();
  return (
    <Row label="Default team key (e.g. ENG)">
      <TextSetting value={snap.settings.linearTeamKey} onCommit={(v) => set("linearTeamKey", v)} />
    </Row>
  );
}

function EmailSection({
  health,
  onSaved,
}: {
  health?: HealthResult;
  onSaved: (id: string) => void;
}) {
  const { snap, set, markSecretSaved } = useSettings();
  const s = snap.settings;
  return (
    <Section title="Email">
      <Row label="Backend">
        <Select value={s.emailBackend} onValueChange={(v) => set("emailBackend", v as typeof s.emailBackend)}>
          <SelectTrigger className="max-w-56">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="smtp">SMTP (app password)</SelectItem>
            <SelectItem value="gmail">Gmail API (OAuth)</SelectItem>
          </SelectContent>
        </Select>
      </Row>
      <Row label="From address">
        <TextSetting value={s.emailFromAddress} onCommit={(v) => set("emailFromAddress", v)} />
      </Row>
      {s.emailBackend === "smtp" ? (
        <>
          <Row label="SMTP host (SSL, port 465)">
            <TextSetting value={s.smtpHost} onCommit={(v) => set("smtpHost", v)} />
          </Row>
          <Row label="SMTP username">
            <TextSetting value={s.smtpUsername} onCommit={(v) => set("smtpUsername", v)} />
          </Row>
          <Row label="App password">
            <SecretField
              label="App password"
              saved={snap.secrets.smtp}
              onSave={async (v) => {
                await bridge("secrets.save", { key: "smtp", value: v });
                markSecretSaved("smtp");
                onSaved("email");
              }}
            />
          </Row>
        </>
      ) : (
        <>
          <Row label="Gmail OAuth access token">
            <SecretField
              label="Access token"
              saved={snap.secrets.gmail}
              onSave={async (v) => {
                await bridge("secrets.save", { key: "gmail", value: v });
                markSecretSaved("gmail");
                onSaved("email");
              }}
            />
          </Row>
          <Hint>Paste a token with gmail.send scope (full OAuth flow ships in Phase 5).</Hint>
        </>
      )}
      <HealthLine health={health} />
    </Section>
  );
}

function GoogleCalendarSection() {
  const { snap, set, markSecretSaved, patchCalendar } = useSettings();
  const s = snap.settings;
  const { hasBuiltInClient, connected } = snap.calendar;
  const [connecting, setConnecting] = React.useState(false);
  const [status, setStatus] = React.useState("");
  const [eventPreview, setEventPreview] = React.useState("");
  const [calendars, setCalendars] = React.useState<CalendarInfo[]>([]);
  const [advancedOpen, setAdvancedOpen] = React.useState(false);

  React.useEffect(() => {
    if (connected) void bridge("calendar.calendars").then((r) => setCalendars(r.calendars));
  }, [connected]);

  const configured = hasBuiltInClient || (s.googleClientID.trim() !== "" && snap.secrets.googleClientSecret);

  const credentialFields = (
    <>
      <Row label="Client ID">
        <TextSetting value={s.googleClientID} onCommit={(v) => set("googleClientID", v)} />
      </Row>
      <Row label="Client secret">
        <SecretField
          label="Client secret"
          saved={snap.secrets.googleClientSecret}
          onSave={async (v) => {
            await bridge("secrets.save", { key: "googleClientSecret", value: v });
            markSecretSaved("googleClientSecret");
          }}
        />
      </Row>
      <Row label="My email (auto-filled on connect)">
        <TextSetting value={s.calendarSelfEmail} onCommit={(v) => set("calendarSelfEmail", v)} />
      </Row>
      <Hint>
        1. In Google Cloud Console, create an OAuth client of type <b>Desktop app</b>. 2. Enable the{" "}
        <b>Google Calendar API</b>. 3. Paste the client ID and secret above. 4. Connect and approve
        read-only calendar access. Tokens are stored in your Keychain; OpenAvatar only ever reads
        events, never writes.
      </Hint>
      <div>
        <ExternalLink href="https://console.cloud.google.com/apis/credentials">
          Open Google Cloud Console
        </ExternalLink>
      </div>
    </>
  );

  return (
    <Section
      title="Google Calendar"
      description="Who's on the call — read-only. It never changes your calendar."
    >
      {connected ? (
        <>
          <div className="flex items-center justify-between gap-2">
            <div className="flex items-center gap-1.5">
              <CheckCircle2 className="size-3.5 text-success" />
              <span className="text-[13px] text-success">Connected to Google Calendar</span>
            </div>
            <div className="flex items-center gap-2">
              <Button
                variant="outline"
                size="sm"
                disabled={connecting}
                onClick={async () => {
                  setConnecting(true);
                  setEventPreview("Reading…");
                  try {
                    const { message } = await bridge("calendar.test");
                    setEventPreview(message);
                  } finally {
                    setConnecting(false);
                  }
                }}
              >
                Test
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={async () => {
                  await bridge("calendar.disconnect");
                  patchCalendar(false);
                  setStatus("Disconnected.");
                  setEventPreview("");
                }}
              >
                Disconnect
              </Button>
            </div>
          </div>
          {eventPreview && <Hint>{eventPreview}</Hint>}
          <Row
            label="Calendar to use"
            hint={`Events, attendees, and the Home "Coming up" list all read from this calendar — pick your work calendar if that's where meetings live.`}
          >
            <Select value={s.calendarID} onValueChange={(v) => set("calendarID", v)}>
              <SelectTrigger className="max-w-72">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {!calendars.some((c) => c.id === s.calendarID) && (
                  <SelectItem value={s.calendarID}>
                    {s.calendarID === "primary" ? "Primary" : s.calendarID}
                  </SelectItem>
                )}
                {calendars.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.isPrimary ? `${c.name} (primary)` : c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Row>
          <Row
            label="Identify who's on the call"
            hint="When you start listening, OpenAvatar looks up the current event and offers each attendee's name to label the voices it hears. On a 1:1 it pre-fills the other person automatically."
          >
            <Switch checked={s.calendarEnabled} onCheckedChange={(v) => set("calendarEnabled", v)} />
          </Row>
        </>
      ) : (
        <div className="flex items-center gap-3">
          <Button
            disabled={connecting || !configured}
            onClick={async () => {
              setConnecting(true);
              setStatus("Opening your browser to sign in…");
              try {
                const result = await bridge("calendar.connect");
                if (result.connected) patchCalendar(true);
                setStatus(result.message);
              } catch (e) {
                setStatus(String(e));
              } finally {
                setConnecting(false);
              }
            }}
          >
            {connecting ? "Connecting…" : "Connect Google Calendar"}
          </Button>
          {hasBuiltInClient ? (
            <Hint>
              One click — pre-fills who you're talking to from your calendar. Tokens stay in your
              Keychain.
            </Hint>
          ) : !configured ? (
            <Status ok={false}>Add an OAuth client below first.</Status>
          ) : null}
        </div>
      )}
      {status && <Hint>{status}</Hint>}
      {hasBuiltInClient ? (
        <div className="flex flex-col gap-3">
          <button
            className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
            onClick={() => setAdvancedOpen((v) => !v)}
          >
            {advancedOpen ? <ChevronDown className="size-3.5" /> : <ChevronRight className="size-3.5" />}
            Advanced — use your own Google app
          </button>
          {advancedOpen && credentialFields}
        </div>
      ) : (
        <>
          <Separator />
          {credentialFields}
        </>
      )}
    </Section>
  );
}

function ManifestSection({
  known,
  health,
  onSaved,
}: {
  known: KnownIntegrations | null;
  health: Record<string, HealthResult>;
  onSaved: (id: string) => void;
}) {
  return (
    <Section
      title="Manifest integrations"
      description="Drop a JSON file — no code needed. See docs/INTEGRATIONS.md for the format."
    >
      {(known?.manifests ?? []).map((m) => (
        <div key={m.id} className="flex flex-col gap-1.5">
          <div className="flex items-center gap-2">
            <span className="text-[13px] font-medium">{m.displayName}</span>
            {m.authHint && <span className="text-[11px] text-muted-foreground/70">{m.authHint}</span>}
          </div>
          <ManifestSecret id={m.id} configured={m.configured} onSaved={onSaved} />
          <HealthLine health={health[m.id]} />
        </div>
      ))}
      <div>
        <Button variant="outline" onClick={() => void bridge("app.openManifestsFolder")}>
          Open manifests folder
        </Button>
      </div>
    </Section>
  );
}

function ManifestSecret({
  id,
  configured,
  onSaved,
}: {
  id: string;
  configured: boolean;
  onSaved: (id: string) => void;
}) {
  const [saved, setSaved] = React.useState(configured);
  return (
    <SecretField
      label="API key / token"
      saved={saved}
      onSave={async (v) => {
        await bridge("secrets.saveDynamic", { integrationID: id, value: v });
        setSaved(true);
        onSaved(id);
      }}
    />
  );
}

function MCPSection({
  known,
  setKnown,
  health,
}: {
  known: KnownIntegrations | null;
  setKnown: (k: KnownIntegrations) => void;
  health: Record<string, HealthResult>;
}) {
  const [name, setName] = React.useState("");
  const [command, setCommand] = React.useState("");
  return (
    <Section
      title="MCP servers"
      description="Any Model Context Protocol server's tools become executable actions."
    >
      {(known?.mcpServers ?? []).map((server) => (
        <div key={server.id} className="flex items-center gap-2">
          <div className="flex min-w-0 flex-1 flex-col">
            <span className="text-[13px]">{server.name}</span>
            <span className="truncate font-mono text-[11px] text-muted-foreground/70">
              {server.command}
            </span>
          </div>
          <HealthLine health={health[`mcp-${server.id}`]} />
          <Button
            variant="ghost"
            size="icon"
            onClick={async () => {
              setKnown(await bridge("mcp.remove", { id: server.id }));
            }}
          >
            <Trash2 className="size-3.5" />
          </Button>
        </div>
      ))}
      <div className="flex items-center gap-2">
        <Input
          placeholder="Name (e.g. notion)"
          className="w-36 shrink-0"
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <Input
          placeholder="Command (e.g. npx -y @notionhq/notion-mcp-server)"
          value={command}
          onChange={(e) => setCommand(e.target.value)}
        />
        <Button
          variant="secondary"
          disabled={!name.trim() || !command.trim()}
          onClick={async () => {
            setKnown(await bridge("mcp.add", { name: name.trim(), command: command.trim() }));
            setName("");
            setCommand("");
          }}
        >
          Add
        </Button>
      </div>
    </Section>
  );
}
