# OpenAvatar — Privacy Policy

**Effective date:** 15 July 2026

OpenAvatar ("the app") is a local‑first macOS application that listens to your
calls, transcribes them on your Mac, and helps you act on decisions and action
items across the tools you connect. This policy explains what the app does and
does not do with your information.

The short version: **OpenAvatar runs entirely on your Mac. The developer
operates no servers, receives no personal data, and uses no analytics or
tracking.**

## Who we are

OpenAvatar is developed by the OpenAvatar project ("we", "us"). For any
privacy question, contact **kocsmy@gmail.com**.

## What the app processes, and where

Everything below happens **locally on your device** unless you explicitly
configure a cloud service (see "Services you connect").

- **Audio.** When — and only when — you turn listening on, the app captures
  microphone audio and, on supported systems, the audio of the call you are on.
  Audio is processed in memory to produce a transcript and is not saved as an
  audio file. The menu‑bar icon always reflects whether capture is active.
- **Transcripts, decisions and actions.** Transcripts, detected decisions,
  actions the app prepares or takes, per‑voice "speaker" fingerprints, and app
  settings are stored **locally** in the app's Application Support folder and,
  for secrets, in the macOS Keychain. They never leave your Mac except through
  services you connect.
- **No developer collection.** We do not receive, store, or have any access to
  your audio, transcripts, calendar, messages, or any other content. There is
  no OpenAvatar account and no OpenAvatar server.
- **No analytics or tracking.** The app contains no telemetry, advertising, or
  third‑party trackers.

## Services you connect (optional, under your control)

OpenAvatar only contacts an external service when you configure it and, for
actions, when you approve them:

- **AI model providers** (e.g. Anthropic, OpenAI, Google, or a local model such
  as Ollama) — used to detect decisions and draft actions. If you choose a
  cloud provider, the relevant transcript text is sent to that provider using
  **your own API key**. If you use a local model, nothing leaves your Mac.
- **Transcription** — local (whisper.cpp) by default, so audio never leaves your
  Mac. If you switch to a cloud transcription service, audio is sent to that
  service using your own key.
- **Integrations** you enable (e.g. GitHub, Slack, Linear, email, Google
  Calendar) — contacted with **your own credentials** to read context or carry
  out actions you approve.

Data sent to these services is handled under **their** privacy policies. You can
disconnect any of them at any time.

## Google Calendar (read‑only)

If you connect Google Calendar, the app requests **read‑only** access
(`calendar.readonly`) solely to look up the event around the current time and
its attendees, so it can suggest names for the voices on your call. Calendar
data is used transiently on your Mac for that purpose and is **not** stored on
any server or sent to the developer. Your Google authorization (refresh token)
is stored only in your macOS Keychain, and you can revoke it any time from
[your Google Account permissions](https://myaccount.google.com/permissions) or
by clicking **Disconnect** in the app.

OpenAvatar's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the **Limited Use** requirements. We do not transfer or use Google user
data for serving ads, and we do not allow humans to read it except as needed for
security or to comply with the law.

## Permissions the app asks for

- **Microphone** and **system audio capture** — to transcribe calls while
  listening is on. macOS shows these permission prompts and lets you revoke them
  in System Settings → Privacy & Security at any time.

## Your control over your data

Because your data lives on your Mac, you are in control:

- Export everything the app has stored, or erase all of it, from
  **Settings → Data**.
- Disconnect any integration or the calendar at any time.
- Deleting the app and its Application Support folder removes local data;
  Keychain items can be removed via Keychain Access.

## Children

OpenAvatar is not directed to children and is not intended for use by anyone
under the age required to consent to call recording where they live.

## Changes to this policy

If this policy changes, we will update the effective date above and post the new
version at this URL. Material changes will be reflected in the app's release
notes.

## Contact

Questions about privacy: **kocsmy@gmail.com**
