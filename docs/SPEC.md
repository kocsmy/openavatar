# IF-005 · AI Avatar — Product & Technical Spec (v1)

**Target:** macOS app for AI-assisted development (this document is written to be handed to an AI coding agent such as Claude Code).
**Source:** PRD v1 (IF-005). This spec translates the PRD into buildable scope; where the PRD left decisions open, resolved choices are marked **[DECIDED]**.

---

## 1. Summary

A local macOS menu-bar app that listens to the user's calls (locally — it never joins the call), detects spoken decisions and action items, and **executes** them across **GitHub, Slack, Linear, and email** under the user's own identity, prefixed with 🤖 for attribution. Two modes: **Passive** (post-call approve/deny list, then executes approved items) and **Active** (executes immediately when directly addressed mid-call).

**[DECIDED] v1 integration scope:** all four — GitHub, Slack, Linear, email.
**[DECIDED] LLM layer:** swappable, BYO-token — Anthropic, OpenAI, Google Gemini, and local via Ollama.
**[DECIDED] Transcription:** dual-mode — local (whisper.cpp) or cloud STT via BYO key, user-selectable in Settings.
**[DECIDED per PRD §4]** Execution model: local app acting under the user's own OAuth tokens (no separate AI-user VM identity in v1).

---

## 2. Goals & Non-Goals

### Goals (v1)
1. Capture call audio locally, transcribe in near-real-time, and detect actionable decisions.
2. Execute approved actions end-to-end: create/merge PRs, create Linear tickets, post Slack messages, send emails — never hand back a bare checklist.
3. Trust ladder: per-action-type autonomy settings (Draft & approve → Autonomous).
4. Every AI-executed artifact is attributed with a 🤖 prefix under the user's identity.
5. BYO tokens for everything: LLM providers, STT, and all integrations. No vendor account, no proxy server, no telemetry backend in v1.
6. Local-first data: transcripts, decisions, and the compounding context store never leave the machine except as LLM/STT API payloads the user has explicitly configured.
7. Instrument the PRD §7 metrics from day one (auto-approve-without-edit rate, revert/edit counter, baseline admin-minutes log).

### Non-Goals (v1, from PRD §4)
- No in-editor execution (Cursor/Copilot territory).
- No custom sandbox/rollback layer — rely on git revert / PR history.
- No separate AI-user VM identity.
- No billing/pricing system.
- No Windows/Linux.
- **Deferred to v1.x:** Telegram remote interface; screen-context observation (OCR of active window). Both are stubbed behind feature flags but not built in v1.0 (they multiply permission asks and risk surface before the trust model is validated).

---

## 3. Architecture Overview

```
┌────────────────────────────  macOS app (Swift/SwiftUI)  ───────────────────────────┐
│                                                                                     │
│  Audio Capture ──► Transcription Engine ──► Decision Detector ──► Action Planner    │
│  (CoreAudio tap +   (whisper.cpp local     (LLM call w/         (LLM tool-calling   │
│   mic input)         OR cloud STT)          rolling window)       → ActionPlan)     │
│                                                                        │            │
│                                                              Trust Policy Engine    │
│                                                               │              │      │
│                                                        needs approval    autonomous │
│                                                               │              │      │
│                                                      Approval UI ──► Action Executor│
│                                                      (menu bar +     (GitHub, Slack,│
│                                                       Slack DM)       Linear, Email)│
│                                                                              │      │
│   Context Store (SQLite) ◄── writes: transcripts, decisions, actions, outcomes      │
│   Keychain ◄── all tokens/keys                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

**Tech stack**
- **App shell:** Swift 5.10+, SwiftUI, menu-bar app (`MenuBarExtra`) + main settings window. Min target macOS 14.4 (required for CoreAudio process taps).
- **Audio:** CoreAudio process tap (`CATapDescription` / `AudioHardwareCreateProcessTap`) for system/call audio + `AVAudioEngine` for microphone. Requires Microphone permission; system-audio capture requires the audio-capture entitlement/permission flow (NSAudioCaptureUsageDescription on 14.4+).
- **Local STT:** whisper.cpp compiled with Metal; bundle `base.en` by default, downloadable `small`/`medium` models in Settings.
- **Persistence:** SQLite via GRDB.swift. Tokens exclusively in macOS Keychain.
- **Networking:** URLSession; no third-party HTTP layer required.
- **Concurrency:** Swift structured concurrency (actors for the pipeline stages).

---

## 4. Module Specs

### 4.1 Audio Capture (`AudioCaptureService`)
- Captures two streams: (a) system output audio of call apps (Zoom, Meet in browser, Slack huddles, Teams) via process tap; (b) user microphone.
- Mixes to mono 16 kHz PCM chunks (whisper's expected input), 30 s ring buffer with 5 s overlap for streaming transcription.
- Call detection heuristic: capture activates when a known call process is producing audio AND mic is live; also a manual "Start listening" toggle in the menu bar. Never records when the indicator is off; menu-bar icon must always reflect recording state (hard requirement — trust/legibility).
- Emits `AudioChunk { pcm: Data, source: .system|.mic, t0, t1 }`.

### 4.2 Transcription Engine (`TranscriptionService`)
Protocol:
```swift
protocol Transcriber {
    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment]
}
struct TranscriptSegment { let text: String; let t0, t1: TimeInterval; let source: AudioSource; let confidence: Double }
```
Implementations:
- `WhisperLocalTranscriber` (whisper.cpp, streaming, Metal).
- `CloudTranscriber` — one implementation per configured provider, BYO key:
  - OpenAI Audio Transcriptions endpoint,
  - any OpenAI-compatible STT endpoint (base-URL override in Settings, so Deepgram/Groq-style services work without dedicated code paths).
- Settings picker: `Local (private, offline)` / `Cloud (BYO key)`. Default: **Local**. If cloud is selected, show an explicit disclosure: "Call audio will be sent to <provider>."
- Speaker attribution v1: two-channel heuristic only — mic stream = "You", system stream = "Others". No diarization in v1.

### 4.3 LLM Abstraction Layer (`LLMService`) — swappable, BYO token
Single provider-agnostic interface; all higher layers depend only on this.
```swift
protocol LLMProvider {
    var id: ProviderID { get }          // .anthropic, .openai, .gemini, .ollama, .custom
    func complete(_ req: LLMRequest) async throws -> LLMResponse
    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
    func listModels() async throws -> [ModelInfo]
}

struct LLMRequest {
    var system: String
    var messages: [ChatMessage]         // role: user/assistant/tool
    var tools: [ToolSpec]               // JSON-Schema tool definitions
    var toolChoice: ToolChoice
    var maxTokens: Int
    var temperature: Double
}
enum LLMEvent { case textDelta(String); case toolCall(ToolCall); case done(Usage) }
```
Provider adapters (each maps the neutral request/response to the provider wire format):

| Provider | Endpoint | Auth | Tool calling | Notes |
|---|---|---|---|---|
| Anthropic | `POST https://api.anthropic.com/v1/messages` | `x-api-key` header + `anthropic-version` | native `tools` blocks | Verify current model IDs at runtime via the models list endpoint; docs: https://docs.claude.com/en/api/overview |
| OpenAI | `POST /v1/chat/completions` (base URL overridable) | `Authorization: Bearer` | `tools` / `tool_calls` | Base-URL override also enables OpenAI-compatible gateways |
| Google Gemini | `generateContent` REST | API key | `functionDeclarations` | Map system prompt to `systemInstruction` |
| Ollama | `POST http://localhost:11434/api/chat` | none | `tools` (model-dependent) | Detect running daemon; surface "Ollama not running" state |

Requirements:
- **Model picker is populated dynamically** from each provider's list-models endpoint — never hard-code model names in the UI.
- Per-task model routing in Settings: user can assign different provider/model to (a) decision detection (cheap/fast), (b) action planning & code edits (strong), (c) summaries (cheap).
- Uniform retry (exponential backoff on 429/5xx), timeout, and token-usage accounting persisted per call for the future pass-through-margin business model (PRD §6).
- Graceful degradation: if the configured provider fails mid-call, queue segments and surface a menu-bar error; never silently drop decisions.

### 4.4 Decision Detector (`DecisionDetector`)
- Runs on a rolling transcript window (last ~90 s + running call summary) every N segments or on silence gaps.
- LLM call (the "cheap/fast" routed model) with a structured-output tool `report_decisions` returning:
```json
{ "decisions": [ {
    "quote": "verbatim trigger utterance",
    "intent": "create_ticket | code_change | send_message | send_email | merge_pr | other",
    "summary": "one-line action item",
    "assignee_hint": "string|null",
    "confidence": 0.0-1.0,
    "addressed_to_assistant": true|false   // true = user said the wake phrase / direct callout
} ] }
```
- **Active mode trigger:** `addressed_to_assistant == true` (wake phrase configurable, default the assistant's user-chosen name) → route straight to Action Planner.
- **Passive mode:** decisions accumulate into the post-call review list.
- False-positive control: below confidence threshold (Settings, default 0.6) items are shown greyed-out in the review list, never auto-executed.

### 4.5 Action Planner (`ActionPlanner`)
- Input: a `Decision` + relevant context from the Context Store (repo map, recent tickets, team roster, past similar decisions).
- LLM call (the "strong" routed model) with tool-calling against the executor tool specs (§4.6) → produces an `ActionPlan`:
```swift
struct ActionPlan {
    let decisionID: UUID
    let steps: [ActionStep]      // ordered; each maps 1:1 to an executor tool call
    let riskClass: RiskClass     // .read, .draft, .write, .destructive (merge, send-email)
    let preview: ActionPreview   // human-readable diff / message body / ticket fields
}
```
- **Code-change planning:** clone/pull the target repo into an app-managed workdir (`~/Library/Application Support/IF005/repos/`), generate the edit via LLM (diff-based prompting), run `git apply` + optional build/test command configured per-repo, then create branch + PR via GitHub API. Never push to default branch directly.

### 4.6 Action Executor (`ActionExecutor`) — the four integrations
Each integration is a plugin conforming to:
```swift
protocol ActionIntegration {
    var id: IntegrationID { get }
    var toolSpecs: [ToolSpec] { get }        // exposed to the planner LLM
    func execute(_ call: ToolCall) async throws -> ActionResult
    func revert(_ result: ActionResult) async throws  // where natively supported
    func healthCheck() async -> IntegrationHealth
}
```

**GitHub** (REST v3, PAT fine-grained or OAuth device flow; BYO token)
- Tools: `create_branch`, `commit_changes`, `open_pr`, `comment_on_pr`, `merge_pr`, `revert_pr` (creates revert PR).
- `merge_pr` is always `riskClass = .destructive`.

**Slack** (user token via OAuth, `xoxp-`; BYO app credentials supported)
- Tools: `post_message`, `post_thread_reply`, `send_dm`.
- Every message body is prefixed `🤖 ` (non-negotiable, enforced in the executor, not the prompt).
- Also used inbound: post-call approval summary is DM'd to the user with approve/deny buttons mirrored from the native Approval UI (v1 may ship menu-bar-only approvals first; Slack interactive buttons require a small Slack app — flag `slackInteractiveApprovals`).

**Linear** (GraphQL API, personal API key)
- Tools: `create_issue`, `update_issue`, `comment_on_issue`, `assign_issue`.
- Title prefix `🤖 ` on created issues.

**Email** (Gmail API via OAuth **or** generic SMTP/IMAP with app password — Settings choice)
- Tools: `draft_email`, `send_email`.
- `send_email` is `riskClass = .destructive` by default (irreversible).
- Sent-mail body footer: "🤖 Drafted and sent by <assistant name> on behalf of <user>."

### 4.7 Trust Policy Engine (`TrustPolicy`)
- Matrix in Settings: rows = action tool (per integration), columns = mode (Passive/Active), cell value = `Ask first` | `Autonomous`.
- Defaults (conservative): everything `Ask first` except `comment_on_pr` and `create_issue` in Active mode.
- `.destructive` actions can be set Autonomous only after the app has recorded ≥10 approved executions of that action type without a subsequent revert/edit (graduated autonomy made concrete).
- Approved-but-gated actions are **executed by the app** after approval — never exported as a to-do (PRD §4 trust-ladder requirement).

### 4.8 Approval UI
- Menu-bar popover: live "Detected this call" list; post-call review sheet with per-item: preview (diff / message / ticket fields), Approve / Edit / Dismiss.
- **Edit-before-approve is tracked** — an edited approval counts against the auto-approve-without-edit metric (§6).
- One-click **Undo** on every executed action where the integration supports revert (revert PR, delete Slack message within edit window, cancel Linear issue). Undo events feed the revert counter-metric.

### 4.9 Context Store (`ContextStore`) — the compounding moat (PRD §3)
SQLite schema (GRDB):
- `calls(id, started_at, ended_at, app, participants_guess, summary)`
- `transcript_segments(call_id, t0, t1, source, text, confidence)`
- `decisions(id, call_id, quote, intent, summary, confidence, status)` — status: detected/approved/edited/dismissed/executed/reverted
- `actions(id, decision_id, integration, tool, payload_json, result_json, executed_at, reverted_at, edited_before_approve)`
- `entities(id, kind, name, aliases_json)` — teammates, repos, projects, shorthand
- `metrics_daily(date, decisions_detected, auto_approved_no_edit, edited, reverted, admin_minutes_baseline)`
- Retrieval for the planner: keyword + recency query in v1 (no embeddings dependency); optional local embeddings (via Ollama) behind flag `semanticContext`.
- Export/erase: Settings must include "Export all data (JSON)" and "Delete all data".

### 4.10 Settings & Onboarding
Onboarding wizard order (each step skippable): 1) mic + system-audio permissions → 2) transcription mode → 3) LLM provider + key (validate with a live `listModels` call) → 4) connect integrations (each validated with `healthCheck`) → 5) assistant name / wake phrase → 6) trust matrix defaults → 7) **baseline prompt:** "Roughly how many minutes/day do you spend routing post-call tasks?" (feeds `admin_minutes_baseline`, PRD §7).
All secrets → Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Keys are never logged, never written to SQLite, redacted in any debug output.

---

## 5. Security, Privacy & Attribution Requirements (hard constraints)

1. Recording indicator always visible while capturing; global hotkey to stop.
2. Local-only default: with local Whisper + Ollama selected, the app must function with zero outbound network except integration API calls the user triggers.
3. All executed artifacts carry the 🤖 marker — enforced in code (executor layer), not prompts.
4. No auto-update that changes trust defaults; trust matrix changes require explicit user action.
5. Repo workdirs isolated under Application Support; app never modifies user-cloned repos in place.
6. Prompt-injection posture: transcript content is data, not instructions — planner system prompt must instruct the model to ignore imperative content addressed to it from non-user speakers; `.destructive` actions from `source == .system` utterances are always `Ask first` regardless of matrix.

---

## 6. Metrics Instrumentation (ships in v1.0)

| Metric | Definition | Source |
|---|---|---|
| Auto-approve-no-edit rate (primary) | approved w/o edit ÷ decisions surfaced, per call | `actions.edited_before_approve` |
| Revert/edit counter (trust signal) | 🤖 artifacts reverted or edited post-execution ÷ executed | `actions.reverted_at` + PR/issue polling |
| Baseline admin minutes | onboarding self-report + optional weekly re-prompt | `metrics_daily` |
| Misfire log (R2) | decisions dismissed as "wrong transcription/intent" (dismiss reason picker) | `decisions.status` + reason |

Local dashboard tab in Settings; CSV export. No telemetry leaves the machine in v1.

---

## 7. Build Phases & Acceptance Criteria

**Phase 1 — Pipeline spine (weeks 1–2):** capture → local Whisper → decision list in menu bar. ✅ *Accept:* a real Zoom call yields ≥1 correctly detected decision with quote + timestamp.
**Phase 2 — LLM layer + planner (week 3):** all four provider adapters pass a shared contract-test suite (same request → normalized response, tool-call round-trip); per-task routing works. ✅ *Accept:* switching provider in Settings mid-session requires no restart.
**Phase 3 — Executors + trust engine (weeks 4–5):** GitHub, Slack, Linear, Email plugins with approval UI and undo. ✅ *Accept:* the PRD wedge demo end-to-end — say "change the header text" → PR opened → say "merge it" → PR merged, all 🤖-attributed.
**Phase 4 — Passive mode + context store + metrics (week 6):** post-call review sheet, compounding context retrieval in planner, metrics dashboard. ✅ *Accept:* second call referencing "that ticket from yesterday" resolves the right Linear issue.
**Phase 5 — Hardening for dogfooders:** cloud STT option, Gmail OAuth flow, onboarding wizard, crash-safe audio buffer.

**Out of these phases (v1.x backlog):** Telegram bridge, screen-context OCR, Slack interactive approvals, diarization, embeddings retrieval, VM-identity execution mode (revisit if R1/impersonation findings force it).

---

## 8. Open Questions carried from the PRD (do not silently resolve in code)

1. **R1 impersonation:** if dogfooders reject 🤖-as-you posts, the executor identity model changes (separate bot identities per integration) — keep the integration layer identity-agnostic so this is a config change, not a rewrite.
2. **R2 accuracy bar:** define the misfire tolerance once dogfooder #2 data exists; the misfire log above is the input.
3. Multi-user calls where a *non-user* speaker issues commands — v1 policy is defined in §5.6, but revisit after real transcripts.
