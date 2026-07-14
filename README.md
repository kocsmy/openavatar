# OpenAvatar

A local macOS menu-bar app that listens to your calls (locally — it never joins them), detects spoken decisions and action items, and **executes** them across **GitHub, Slack, Linear, and email** under your own identity, prefixed with 🤖 for attribution.

Built from the IF-005 product spec — see [`docs/SPEC.md`](docs/SPEC.md).

## How it works

```
Audio Capture ──► Transcription ──► Decision Detector ──► Action Planner
(CoreAudio tap     (whisper.cpp      (LLM, rolling         (LLM tool-calling
 + mic)             or cloud STT)     window)               → ActionPlan)
                                                                 │
                                                        Trust Policy Engine
                                                        │               │
                                                  needs approval   autonomous
                                                        │               │
                                                  Approval UI ──► Action Executor
                                                                  (GitHub, Slack,
                                                                   Linear, Email)
```

- **Passive mode** (default): decisions accumulate during the call; when it ends you get a review sheet — Approve / Edit / Dismiss. Approved items are **executed by the app**, never handed back as a to-do list.
- **Active mode**: say "*<assistant name>*, open a ticket for that" mid-call and it happens immediately — for action types you've marked Autonomous in the trust matrix.
- **Trust ladder**: every action type starts as *Ask first*. Destructive actions (merge PR, send email) can only be set Autonomous after **10 approved executions with no revert and no edit**. Requests spoken by *other* call participants are never executed destructively without your approval.
- **🤖 attribution** is enforced in the executor code (not prompts): Slack messages, Linear titles, PR titles/comments, and email footers all carry the marker.
- **Compounding memory**: every call is distilled into a digest + durable facts (identity, preferences, projects, people, commitments, patterns) with salience that reinforces or decays over time. A token-budgeted briefing feeds detection and planning, and open commitments drive proactive suggestions in the menu bar — always Ask-first. Inspect or wipe it all in Settings → Memory.
- **Unbounded integrations**: beyond the 4 native plugins, add integrations by dropping a JSON manifest (generic HTTP engine, no code) or pointing at any MCP server (its tools are discovered at runtime). See [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Privacy posture

- **Local-first**: transcripts, decisions, actions, and metrics live in a local SQLite DB (`~/Library/Application Support/OpenAvatar/`). Nothing leaves the machine except LLM/STT API calls you explicitly configured and the integration API calls you approve.
- **BYO tokens for everything** — LLM (Anthropic / OpenAI / Gemini / Ollama), STT, GitHub, Slack, Linear, email. All secrets live in the macOS Keychain (`WhenUnlockedThisDeviceOnly`), never in SQLite or logs.
- **Fully offline option**: local Whisper + Ollama = zero outbound network except the integrations you trigger.
- The menu-bar icon **always** reflects recording state; ⌘⇧L stops capture instantly. Nothing records unless you switch it on.
- Settings → Data: export everything as JSON, or delete everything.

## Requirements

- macOS **14.4+** (CoreAudio process taps for system-audio capture)
- Xcode 15.4+ / Swift 5.10 toolchain
- For local transcription: `brew install whisper-cpp` + a ggml model, e.g.
  [`ggml-base.en.bin`](https://huggingface.co/ggerganov/whisper.cpp/tree/main)
- Optional: [Ollama](https://ollama.com) for a fully local LLM

## Build & run

```sh
# App bundle (recommended — carries the mic/system-audio usage descriptions):
./scripts/make-app.sh
open build/OpenAvatar.app

# Tests (LLM adapter contract suite, trust policy, attribution, parsing):
swift test
```

**Auto-updates:** after the first install, the app keeps itself current via [Sparkle](https://sparkle-project.org) — it checks the GitHub Releases appcast hourly, downloads updates in the background, and asks to relaunch. Updates are EdDSA-signed in CI (`SPARKLE_ED_PRIVATE_KEY` repo secret; public key in `Resources/Info.plist`). Manual check: Settings → General → "Check for updates now".

First launch opens an onboarding wizard that walks through permissions, transcription mode, LLM keys (validated live against each provider's model-list endpoint), integrations (validated with health checks), the wake phrase, trust defaults, and the admin-minutes baseline for the metrics dashboard.

### Tokens you'll need

| Integration | Token | Notes |
|---|---|---|
| GitHub | fine-grained PAT | contents:rw + pull-requests:rw on the repos you'll use |
| Slack | user token (`xoxp-`) | scopes: `chat:write`, `im:write`, `users:read` |
| Linear | personal API key | Settings → API in Linear |
| Email | SMTP app password **or** Gmail OAuth token | SMTP over SSL (port 465) works with Gmail/Fastmail app passwords |

## Project layout

```
Sources/OpenAvatar/
  Audio/          mic capture (AVAudioEngine) + system audio (CoreAudio process tap)
  Transcription/  whisper.cpp (local) and OpenAI-compatible cloud STT
  LLM/            provider-agnostic layer: Anthropic, OpenAI(+compatible), Gemini, Ollama
                  + per-task routing, retry/backoff, token-usage accounting
  Detection/      rolling-window decision detector (structured-output tool)
  Planning/       action planner (tool-calling) + app-managed git workdirs
  Trust/          trust matrix policy + graduated autonomy
  Execution/      GitHub / Slack / Linear / Email plugins, 🤖 enforcement, undo
  Store/          SQLite (GRDB) context store + metrics
  Security/       Keychain wrapper + log redaction
  UI/             menu-bar popover, approvals, settings, trust matrix,
                  metrics dashboard, onboarding wizard
Tests/OpenAvatarTests/   contract + policy + parsing tests (run on any Mac, no keys needed)
```

## Status vs. spec phases

- **Phase 1–4** implemented: capture → local whisper → detection; 4 LLM adapters + routing; 4 executors + trust engine + approval UI + undo; passive mode + context store retrieval + metrics dashboard.
- **Phase 5** partially implemented: cloud STT ✅, onboarding wizard ✅; Gmail full OAuth flow is stubbed (paste a token), crash-safe audio buffering is basic.
- **v1.x backlog** (feature-flagged off, not built): Telegram bridge, screen-context OCR, Slack interactive approvals, diarization, embeddings retrieval.

## Notes for contributors

- This codebase was authored in a Linux CI environment and has **not yet been compiled against the macOS SDK** — expect to fix a handful of platform-API compile errors (most likely in `SystemAudioTap.swift`) on first build.
- Prompt-injection posture: transcript content is treated as data. The planner's system prompt instructs the model to ignore imperative transcript content, and — independently of the model — the trust engine forces approval for destructive actions triggered by non-user speakers.
