import type { BridgeAPI, BridgeMethod, Snapshot, TranscriptionStatus, TrustRow } from "./types";

/*
 * Browser-only stand-in for the Swift bridge: realistic sample data with a
 * little latency, so the UI can be built, reviewed, and screenshotted without
 * the macOS host. Never shipped behavior — inside the app the webkit handler
 * always wins.
 */
export function createMockBridge() {
  const snapshot: Snapshot = {
    settings: {
      assistantName: "Avatar",
      userDisplayName: "Zsolt Kocsmárszky",
      mode: "passive",
      autoStartOnCall: true,
      meetingPromptEnabled: true,
      confidenceThreshold: 0.6,
      transcriptionMode: "parakeet",
      whisperCLIPath: "/opt/homebrew/bin/whisper-cli",
      whisperModelPath: "~/Library/Application Support/OpenAvatar/models/ggml-small.bin",
      cloudSTTBaseURL: "https://api.openai.com/v1",
      cloudSTTModel: "whisper-1",
      transcriptionLanguage: "auto",
      diarizationEnabled: true,
      customVocabulary: "PostHog, Termly, Linear",
      openAIBaseURL: "https://api.openai.com/v1",
      ollamaBaseURL: "http://localhost:11434",
      emailBackend: "smtp",
      smtpHost: "smtp.gmail.com",
      smtpUsername: "kocsmy@gmail.com",
      emailFromAddress: "kocsmy@gmail.com",
      googleClientID: "",
      calendarEnabled: true,
      calendarSelfEmail: "kocsmy@gmail.com",
      calendarID: "primary",
      githubDefaultRepo: "kocsmy/openavatar",
      linearTeamKey: "ENG",
      slackDefaultChannel: "#general",
    },
    secrets: {
      anthropic: true,
      openai: false,
      gemini: false,
      cloudSTT: false,
      github: true,
      slack: true,
      linear: false,
      smtp: true,
      gmail: false,
      googleClientSecret: false,
    },
    routes: {
      detection: { provider: "anthropic", model: "claude-haiku-4-5-20251001" },
      planning: { provider: "anthropic", model: "claude-sonnet-5" },
      summary: { provider: "anthropic", model: "claude-haiku-4-5-20251001" },
    },
    version: "1.31.0",
    dbPath: "~/Library/Application Support/OpenAvatar/openavatar.sqlite",
    calendar: { hasBuiltInClient: true, connected: true },
    languages: [
      { code: "auto", label: "Auto-detect (multilingual)" },
      { code: "en", label: "English" },
      { code: "hu", label: "Hungarian" },
      { code: "de", label: "German" },
      { code: "fr", label: "French" },
      { code: "es", label: "Spanish" },
    ],
  };

  const transcription: TranscriptionStatus = {
    parakeet: { state: "ready", message: "" },
    whisper: { ready: true, activeModel: "ggml-small.bin", phase: "idle", message: "" },
    qwen: { runtimeInstalled: true, phase: "idle", message: "" },
  };

  const trustRows: TrustRow[] = [
    { tool: "github.create_branch", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "github.commit_changes", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "github.open_pr", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "github.comment_on_pr", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "autonomous" },
    { tool: "github.merge_pr", risk: "destructive", graduated: false, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "slack.post_message", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "slack.send_dm", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "linear.create_issue", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "autonomous" },
    { tool: "linear.update_issue", risk: "write", graduated: true, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "email.draft_email", risk: "draft", graduated: true, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "email.send_email", risk: "destructive", graduated: false, dynamic: false, passive: "ask_first", active: "ask_first" },
    { tool: "notion.create_page", risk: "write", graduated: true, dynamic: true, passive: "ask_first", active: "ask_first" },
  ];

  let facts = [
    { id: "1", category: "identity", content: "Founder/design engineer shipping OpenAvatar", salience: 4.5, lastReinforced: "Aug 11" },
    { id: "2", category: "preference", content: "Prefers Linear tickets over GitHub issues", salience: 3.5, lastReinforced: "Aug 8" },
    { id: "3", category: "project", content: "Working on OpenAvatar's v1.31 web settings", salience: 4.0, lastReinforced: "Aug 12" },
    { id: "4", category: "person", content: "Vasilis — analytics collaborator (GA4/GTM)", salience: 3.0, lastReinforced: "Aug 6" },
    { id: "5", category: "commitment", content: "Send the JTM script IDs by tomorrow", salience: 4.0, lastReinforced: "Aug 11" },
  ];

  const delay = (ms = 120) => new Promise((r) => setTimeout(r, ms));

  return async function mock<M extends BridgeMethod>(
    method: M,
    params: BridgeAPI[M][0],
  ): Promise<BridgeAPI[M][1]> {
    await delay();
    const p = params as Record<string, unknown>;
    switch (method as BridgeMethod) {
      case "settings.snapshot":
        return snapshot as BridgeAPI[M][1];
      case "settings.set": {
        (snapshot.settings as unknown as Record<string, unknown>)[p.key as string] = p.value;
        return {} as BridgeAPI[M][1];
      }
      case "secrets.save": {
        snapshot.secrets[p.key as keyof Snapshot["secrets"]] = true;
        return {} as BridgeAPI[M][1];
      }
      case "routes.set": {
        const { task, provider, model } = p as { task: string; provider: string | null; model: string };
        if (provider) {
          (snapshot.routes as Record<string, unknown>)[task] = { provider, model };
        } else {
          delete (snapshot.routes as Record<string, unknown>)[task];
        }
        return {} as BridgeAPI[M][1];
      }
      case "routes.test":
        await delay(700);
        return {
          results: [
            { task: "detection", ok: true, message: "✓ claude-haiku-4-5: OK" },
            { task: "planning", ok: true, message: "✓ claude-sonnet-5: OK" },
            { task: "summary", ok: true, message: "✓ claude-haiku-4-5: OK" },
          ],
        } as BridgeAPI[M][1];
      case "models.list":
        await delay(400);
        return {
          models: [
            { id: "claude-sonnet-5", displayName: "Claude Sonnet 5" },
            { id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5" },
            { id: "claude-opus-5", displayName: "Claude Opus 5" },
          ],
        } as BridgeAPI[M][1];
      case "usage.recent":
        return {
          rows: [
            { task: "detection", displayName: "Decision detection", calls: 412, inputTokens: 1_830_000, outputTokens: 96_000, cacheReadTokens: 1_410_000 },
            { task: "summary", displayName: "Summaries", calls: 38, inputTokens: 890_000, outputTokens: 214_000, cacheReadTokens: 0 },
            { task: "planning", displayName: "Action planning & code edits", calls: 21, inputTokens: 240_000, outputTokens: 58_000, cacheReadTokens: 122_000 },
          ],
        } as BridgeAPI[M][1];
      case "transcription.status":
        return transcription as BridgeAPI[M][1];
      case "transcription.setupWhisper":
      case "transcription.prepareParakeet":
      case "transcription.setupQwen":
        return {} as BridgeAPI[M][1];
      case "integrations.known":
        return {
          manifests: [
            { id: "todoist", displayName: "Todoist", configured: false, authHint: "Todoist API token" },
            { id: "notion", displayName: "Notion", configured: true, authHint: "Notion internal integration secret" },
          ],
          mcpServers: [{ id: "notion-mcp", name: "notion", command: "npx -y @notionhq/notion-mcp-server" }],
        } as BridgeAPI[M][1];
      case "integrations.check":
        await delay(500);
        return { id: p.id, ok: true, message: "Connected" } as BridgeAPI[M][1];
      case "integrations.checkAll":
        await delay(900);
        return {
          results: [
            { id: "github", ok: true, message: "Authenticated as kocsmy" },
            { id: "slack", ok: true, message: "Workspace: PostHog" },
            { id: "linear", ok: false, message: "No API key saved" },
            { id: "email", ok: true, message: "SMTP login OK" },
          ],
        } as BridgeAPI[M][1];
      case "mcp.add":
      case "mcp.remove":
        return {
          manifests: [],
          mcpServers: [{ id: "notion-mcp", name: "notion", command: "npx -y @notionhq/notion-mcp-server" }],
        } as BridgeAPI[M][1];
      case "calendar.connect":
        await delay(800);
        snapshot.calendar.connected = true;
        return { connected: true, message: "Connected. Calendar look-up is ready." } as BridgeAPI[M][1];
      case "calendar.disconnect":
        snapshot.calendar.connected = false;
        return {} as BridgeAPI[M][1];
      case "calendar.test":
        await delay(600);
        return { message: "“Sync with Acme” — Alice Ng, Ben Ortiz" } as BridgeAPI[M][1];
      case "calendar.calendars":
        return {
          calendars: [
            { id: "primary", name: "Personal", isPrimary: true },
            { id: "work@group.calendar.google.com", name: "Work", isPrimary: false },
          ],
        } as BridgeAPI[M][1];
      case "trust.rows":
        return { graduationThreshold: 10, rows: trustRows } as BridgeAPI[M][1];
      case "trust.set": {
        const row = trustRows.find((r) => r.tool === p.tool);
        if (row) row[p.mode as "passive" | "active"] = p.setting as TrustRow["passive"];
        return {} as BridgeAPI[M][1];
      }
      case "memory.facts":
        return {
          facts,
          digests: [
            "Planned the v1.31 web settings experiment; shadcn UI in a WKWebView.",
            "Reviewed June ARR with the team; churn still the main concern.",
          ],
        } as BridgeAPI[M][1];
      case "memory.retire":
        facts = facts.filter((f) => f.id !== p.id);
        return {} as BridgeAPI[M][1];
      case "memory.wipe":
        facts = [];
        return {} as BridgeAPI[M][1];
      case "errors.recent":
        return { errors: [] } as BridgeAPI[M][1];
      case "data.export":
        await delay(400);
        return { message: "Exported to ~/Downloads/openavatar-export.json" } as BridgeAPI[M][1];
      default:
        return {} as BridgeAPI[M][1];
    }
  };
}
