# OpenAvatar web UI

The Settings window's frontend: React + Tailwind v4 + shadcn-style components,
rendered inside a WKWebView (`Sources/OpenAvatar/WebUI/WebSettingsWindow.swift`).
This is the experiment that swaps SwiftUI for a web UI, window by window.

## How it talks to the app

`src/lib/bridge.ts` calls `webkit.messageHandlers.avatar.postMessage({method, params})`,
which returns a Promise answered by `SettingsBridge.swift`. The method/shape
contract lives in `src/lib/types.ts` — keep it in sync with the Swift side
(pinned by `Tests/OpenAvatarTests/WebBridgeTests.swift`).

Outside the app (vite dev, screenshots) `src/lib/mock.ts` answers instead with
sample data, so the whole UI works in a plain browser.

## Commands

```sh
npm ci            # install
npm run dev       # live dev server with the mock bridge
npm run build     # dist/ — packaged into OpenAvatar.app/Contents/Resources/WebUI
node screenshot.mjs out/   # headless screenshots of every page, light + dark
```

CI builds `dist/` on every run; `scripts/make-app.sh` copies it into the app
bundle. Assets must stay relative (`base: "./"` in vite.config.ts) because the
page loads from a `file://` URL inside the bundle.
