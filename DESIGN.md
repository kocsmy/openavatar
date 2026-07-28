# OpenAvatar design system

The visual language for product surfaces (Home, Meetings, popover, call
window). Setup/settings tabs deliberately stay on stock macOS grouped forms —
that is what configuration should look like. Tokens and components live in
`Sources/OpenAvatar/UI/DesignSystem.swift`; use them instead of ad-hoc values.

Mood: Craft-like warmth on a native macOS body. Calm surfaces, one warm
accent, strong titles, generous whitespace, everything clickable responds to
hover.

## Rules

- **One tint.** `Color.brand` (warm coral, `0.82/0.44/0.31` — the app icon).
  It marks interactive and identity moments: primary buttons, selected states,
  conference chips, icon plates, "today". Everything else uses semantic system
  colors so both appearances stay correct. Red is reserved for recording/stop,
  green for success/now, orange for needs-attention.
- **Spacing** comes from the `DS.s*` scale (4-base). Tight inside a group
  (4–12), generous between groups (24–32). More space above a heading than
  below it.
- **Type roles** (all SF): `dsPageTitle` 26 bold (meeting page),
  `dsScreenTitle` 21 semibold (screen headers), `dsRowTitle` 13 medium,
  `dsBody` 13, `dsMeta` 11, plus `DSSectionLabel` (11 semibold uppercase,
  kerned) for group labels. Don't invent sizes.
- **Every clickable row** uses `DSRow` (card = persistent quiet surface that
  raises on hover; ghost = transparent until hovered). Hover + pressed states
  are non-negotiable.
- **Metadata is dot-separated text** (`DSMetaLine`), not a row of capsules.
  Capsules (`DSChip`) are only for state ("Executed", "Now") and identity
  ("Google Meet").
- **Icon plates** (`DSIconPlate`) are the signature leading element for
  headers and status rows: tinted rounded square + SF Symbol.
- **Refuse** (from impeccable.style): decorative colored left/right bars on
  rows; nested cards; kickers/eyebrows above headings; gradient text;
  monospace as decoration. Depth only where it clarifies.
- **Reading width:** long-form content (notes, transcripts) caps at ~720–760pt
  and stays leading-aligned in wide windows.
