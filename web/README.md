# OpenAvatar web UI

The app's frontend: React + Tailwind v4 + shadcn-style components, rendered
inside WKWebViews by `Sources/OpenAvatar/WebUI/`. SwiftUI still owns the
process — audio capture, the menu-bar item, permissions, everything native —
but the pixels are here.

## Surfaces

One bundle serves every window. The Swift host loads
`openavatar-ui://app/index.html?surface=<id>`, and `src/main.tsx` mounts the
matching root as a dynamic import, so a window only parses its own chunk.

| surface      | window                          | root                        |
| ------------ | ------------------------------- | --------------------------- |
| `settings`   | Settings                        | `src/App.tsx`               |
| `main`       | Home, Meetings, Follow-ups…     | `src/surfaces/Main.tsx`     |
| `call`       | Call notes (live transcript)    | `src/surfaces/Call.tsx`     |
| `onboarding` | First run                       | `src/surfaces/Onboarding.tsx` |
| `menu`       | Menu-bar popover                | `src/surfaces/MenuBar.tsx`  |

## How it talks to the app

`src/lib/bridge.ts` calls `webkit.messageHandlers.avatar.postMessage({method, params})`,
which returns a Promise answered by `AppBridge.swift` — a router over one small
bridge per surface (`WebUI/Bridges/`). The method/shape contract is split the
same way: `src/lib/types.ts` for settings, `src/lib/types/<surface>.ts` for the
rest. Keep both halves in sync (`Tests/OpenAvatarTests/WebBridgeTests.swift`
pins the parts that silently break).

State flows the other way as events, not diffs: `WebEventBus` emits a topic
("state", "transcript", …) and the page refetches through the `useLive` hook in
`src/components/live.tsx`. Replicating app state on this side of the boundary
would mean maintaining it twice.

Outside the app (vite dev, screenshots) `src/lib/mock.ts` and
`src/lib/mock/<surface>.ts` answer instead with sample data, so the whole UI
works in a plain browser.

## Commands

```sh
npm ci            # install
npm run dev       # live dev server with the mock bridge (?surface= to pick one)
npm run build     # dist/ — packaged into OpenAvatar.app/Contents/Resources/WebUI
node screenshot.mjs out/          # every surface, light + dark
node screenshot.mjs out/ menu     # just one
```

CI builds `dist/` on every run; `scripts/make-app.sh` copies it into the app
bundle before codesigning, so the signature seals it. Assets stay relative
(`base: "./"` in vite.config.ts).
