/*
 * The bridge contract. Every shape here is produced by
 * Sources/OpenAvatar/WebUI/SettingsBridge.swift — keep the two in sync.
 */

import type { HomeAPI } from "./types/home";
import type { MetricsAPI } from "./types/metrics";
import type { MeetingsAPI } from "./types/meetings";
import type { FollowupsAPI } from "./types/followups";
import type { CallAPI } from "./types/call";
import type { OnboardingAPI } from "./types/onboarding";
import type { MenuAPI } from "./types/menu";


export type AssistantMode = "passive" | "active";
export type TranscriptionMode = "local" | "parakeet" | "qwen" | "cloud";
export type EmailBackend = "smtp" | "gmail";
export type LLMTask = "detection" | "planning" | "summary";
export type ProviderID = "anthropic" | "openai" | "gemini" | "ollama";
export type TrustChoice = "ask_first" | "autonomous";

/** Logical secret slots. The web side only ever learns whether one is saved. */
export type SecretKey =
  | "anthropic"
  | "openai"
  | "gemini"
  | "cloudSTT"
  | "github"
  | "slack"
  | "linear"
  | "smtp"
  | "gmail"
  | "googleClientSecret";

export interface Settings {
  assistantName: string;
  userDisplayName: string;
  mode: AssistantMode;
  autoStartOnCall: boolean;
  meetingPromptEnabled: boolean;
  confidenceThreshold: number;
  transcriptionMode: TranscriptionMode;
  whisperCLIPath: string;
  whisperModelPath: string;
  cloudSTTBaseURL: string;
  cloudSTTModel: string;
  transcriptionLanguage: string;
  diarizationEnabled: boolean;
  customVocabulary: string;
  openAIBaseURL: string;
  ollamaBaseURL: string;
  emailBackend: EmailBackend;
  smtpHost: string;
  smtpUsername: string;
  emailFromAddress: string;
  googleClientID: string;
  calendarEnabled: boolean;
  calendarSelfEmail: string;
  calendarID: string;
  githubDefaultRepo: string;
  linearTeamKey: string;
  slackDefaultChannel: string;
}

export interface ModelRoute {
  provider: ProviderID;
  model: string;
}

export interface Snapshot {
  settings: Settings;
  secrets: Record<SecretKey, boolean>;
  routes: Partial<Record<LLMTask, ModelRoute>>;
  version: string;
  dbPath: string;
  calendar: { hasBuiltInClient: boolean; connected: boolean };
  languages: { code: string; label: string }[];
}

export interface ModelInfo {
  id: string;
  displayName: string;
}

export interface RouteTestResult {
  task: LLMTask;
  ok: boolean;
  message: string;
}

export interface UsageRow {
  task: string;
  displayName: string;
  calls: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
}

export type SetupPhase =
  | "idle"
  | "busy"
  | "done"
  | "failed";

export interface TranscriptionStatus {
  parakeet: { state: "idle" | "preparing" | "ready" | "failed"; message: string };
  whisper: { ready: boolean; activeModel: string; phase: SetupPhase; message: string };
  qwen: { runtimeInstalled: boolean; phase: SetupPhase; message: string };
}

export interface HealthResult {
  id: string;
  ok: boolean;
  message: string;
}

export interface KnownIntegrations {
  manifests: { id: string; displayName: string; configured: boolean; authHint: string }[];
  mcpServers: { id: string; name: string; command: string }[];
}

export interface CalendarInfo {
  id: string;
  name: string;
  isPrimary: boolean;
}

export interface TrustRow {
  tool: string;
  risk: "read" | "draft" | "write" | "destructive";
  graduated: boolean;
  dynamic: boolean;
  passive: TrustChoice;
  active: TrustChoice;
}

export interface MemoryFact {
  id: string;
  category: string;
  content: string;
  salience: number;
  lastReinforced: string;
}

export interface ErrorEntry {
  at: string;
  message: string;
}

/** method name → [params, result] */
export interface SettingsBridgeAPI {
  "settings.snapshot": [Record<string, never>, Snapshot];
  "settings.set": [{ key: keyof Settings; value: string | number | boolean }, Record<string, never>];
  "secrets.save": [{ key: SecretKey; value: string }, Record<string, never>];
  "secrets.saveDynamic": [{ integrationID: string; value: string }, Record<string, never>];
  "routes.set": [
    { task: LLMTask; provider: ProviderID | null; model: string },
    Record<string, never>,
  ];
  "routes.test": [Record<string, never>, { results: RouteTestResult[] }];
  "models.list": [{ provider: ProviderID }, { models: ModelInfo[] }];
  "usage.recent": [Record<string, never>, { rows: UsageRow[] }];
  "transcription.status": [Record<string, never>, TranscriptionStatus];
  "transcription.setupWhisper": [{ model?: string }, Record<string, never>];
  "transcription.prepareParakeet": [Record<string, never>, Record<string, never>];
  "transcription.setupQwen": [Record<string, never>, Record<string, never>];
  "integrations.known": [Record<string, never>, KnownIntegrations];
  "integrations.check": [{ id: string }, HealthResult];
  "integrations.checkAll": [Record<string, never>, { results: HealthResult[] }];
  "mcp.add": [{ name: string; command: string }, KnownIntegrations];
  "mcp.remove": [{ id: string }, KnownIntegrations];
  "calendar.connect": [Record<string, never>, { connected: boolean; message: string }];
  "calendar.disconnect": [Record<string, never>, Record<string, never>];
  "calendar.test": [Record<string, never>, { message: string }];
  "calendar.calendars": [Record<string, never>, { calendars: CalendarInfo[] }];
  "trust.rows": [Record<string, never>, { graduationThreshold: number; rows: TrustRow[] }];
  "trust.set": [
    { tool: string; mode: AssistantMode; setting: TrustChoice },
    Record<string, never>,
  ];
  "memory.facts": [Record<string, never>, { facts: MemoryFact[]; digests: string[] }];
  "memory.retire": [{ id: string }, Record<string, never>];
  "memory.wipe": [Record<string, never>, Record<string, never>];
  "errors.recent": [Record<string, never>, { errors: ErrorEntry[] }];
  "errors.clear": [Record<string, never>, Record<string, never>];
  "data.export": [Record<string, never>, { message: string }];
  "data.eraseAll": [Record<string, never>, Record<string, never>];
  "app.checkUpdates": [Record<string, never>, Record<string, never>];
  "app.rerunOnboarding": [Record<string, never>, Record<string, never>];
  "app.openURL": [{ url: string }, Record<string, never>];
  "app.openManifestsFolder": [Record<string, never>, Record<string, never>];
}

/*
 * The full contract is the settings window's methods plus one interface per
 * surface, each declared next to the page that uses it (web/src/lib/types/).
 * Swift's side is split the same way, one file per bridge.
 */
export interface UIBridgeAPI {
  /** Content height for the surfaces the host has to size itself (popover). */
  "ui.resize": [{ height: number }, Record<string, never>];
  /** Open another window. `section` deep-links a settings section. */
  "window.open": [
    { window: "settings" | "main" | "call" | "onboarding"; section?: string },
    Record<string, never>,
  ];
  /** Close the window this page is rendered in (onboarding "Finish"). */
  "window.close": [Record<string, never>, Record<string, never>];
}

export interface BridgeAPI
  extends SettingsBridgeAPI,
    UIBridgeAPI,
    HomeAPI,
    MetricsAPI,
    MeetingsAPI,
    FollowupsAPI,
    CallAPI,
    OnboardingAPI,
    MenuAPI {}

export type BridgeMethod = keyof BridgeAPI;

/**
 * What the host pushes when something changed. The page refetches rather than
 * receiving a diff — see WebEventBus.swift.
 */
export type EventTopic = "state" | "transcript" | "meetings" | "followups" | "errors";
