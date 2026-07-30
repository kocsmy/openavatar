import SwiftUI

/// The OpenAvatar design system — the "Craft pass" (v1.25).
///
/// Rules this file encodes (from impeccable.style, adapted to macOS Operate
/// surfaces, with Craft as the mood board):
/// - ONE tint: the warm coral brand. Interactive and identity moments only;
///   everything else uses semantic system colors so dark mode stays right.
/// - 4-base spacing scale. Tight inside a group, generous between groups,
///   more space above a heading than below it.
/// - Few type roles with obvious contrast, all SF.
/// - Every clickable row has hover and pressed states — the single biggest
///   thing stock macOS forms lack.
/// - No decorative colored side-bars, no nested cards, capsules only where
///   they carry state or identity (not for every scrap of metadata).
enum DS {
    // Spacing (pt). s4/s8/s12/s16 inside groups; s24/s32 between sections.
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32

    /// Corner radii: small for chips/controls, medium for rows, large for pages.
    static let rSmall: CGFloat = 6
    static let rMedium: CGFloat = 10
    static let rLarge: CGFloat = 14

    /// Surface fills built from `.primary` so they adapt to both appearances.
    static let surface = Color.primary.opacity(0.045)
    static let surfaceHover = Color.primary.opacity(0.07)
    static let surfacePressed = Color.primary.opacity(0.10)
    static let hairline = Color.primary.opacity(0.07)
    static let hairlineHover = Color.primary.opacity(0.12)
}

extension Color {
    /// OpenAvatar's warm coral brand accent (matches the app icon).
    static let brand = Color(red: 0.82, green: 0.44, blue: 0.31)
    /// Soft brand wash for icon plates and selected fills.
    static let brandSoft = Color.brand.opacity(0.14)
}

extension Font {
    /// Meeting page title — the one big display moment.
    static let dsPageTitle = Font.system(size: 26, weight: .bold)
    /// Screen headers (Home, Meetings).
    static let dsScreenTitle = Font.system(size: 21, weight: .semibold)
    /// Row titles.
    static let dsRowTitle = Font.system(size: 13, weight: .medium)
    /// Body copy on product surfaces (matches the macOS body size).
    static let dsBody = Font.system(size: 13)
    /// Metadata lines.
    static let dsMeta = Font.system(size: 11)
    /// Long-form reading (meeting notes, summaries) — larger than UI chrome
    /// because these are documents people actually read, not controls.
    static let dsReading = Font.system(size: 14)
    /// Section headings inside long-form reading.
    static let dsReadingHeading = Font.system(size: 15, weight: .semibold)
}

// MARK: - Section label

/// Small uppercase label that separates groups ("TODAY", "COMING UP").
struct DSSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Interactive row

enum DSRowStyle {
    /// Persistent quiet surface that raises on hover (lists of content).
    case card
    /// Transparent until hovered (menu rows inside a popover).
    case ghost
}

/// A clickable row with hover + pressed feedback. Wrap the row's content;
/// the surface, hairline, and press animation are handled here so every
/// list in the app behaves identically.
struct DSRow<Content: View>: View {
    var style: DSRowStyle = .card
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .contentShape(RoundedRectangle(cornerRadius: DS.rMedium, style: .continuous))
        }
        .buttonStyle(DSRowButtonStyle(style: style, hovering: hovering))
        .onHover { hovering = $0 }
    }
}

struct DSRowButtonStyle: ButtonStyle {
    let style: DSRowStyle
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: DS.rMedium, style: .continuous)
        configuration.label
            .background(shape.fill(fill(pressed: pressed)))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return DS.surfacePressed }
        switch style {
        case .card: return hovering ? DS.surfaceHover : DS.surface
        case .ghost: return hovering ? DS.surfaceHover : .clear
        }
    }

    private var stroke: Color {
        switch style {
        case .card: return hovering ? DS.hairlineHover : DS.hairline
        case .ghost: return .clear
        }
    }
}

// MARK: - Chip

/// Capsule for state or identity ("Google Meet", "Executed") — not for plain
/// metadata, which reads better as dot-separated text.
struct DSChip: View {
    let text: String
    var tint: Color = .brand

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, DS.s6 + 1)
            .padding(.vertical, 2)
            .background(tint.opacity(0.13), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Icon plate

/// Rounded-square tinted plate behind an SF Symbol — the app's signature
/// leading element for headers and status rows.
struct DSIconPlate: View {
    let systemName: String
    var tint: Color = .brand
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Metadata line

/// "14:00 – 14:45  ·  45 min  ·  Zoom" — one quiet line instead of a row of
/// capsules.
struct DSMetaLine: View {
    let parts: [String]

    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.dsMeta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
