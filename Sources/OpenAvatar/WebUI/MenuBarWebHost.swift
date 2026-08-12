#if canImport(WebKit) && canImport(AppKit)
import SwiftUI
import WebKit

/// The menu-bar popover, rendered by the web UI.
///
/// MenuBarExtra sizes itself to its content, and a web view has no intrinsic
/// size — so the page measures itself and reports back through `ui.resize`.
/// The width is fixed (a popover that changes width while you read it feels
/// broken); only the height follows the content.
struct MenuBarWebContent: View {
    private static let width: CGFloat = 380

    @State private var height: CGFloat = 380

    var body: some View {
        MenuBarWebView(height: $height)
            .frame(width: Self.width, height: height)
    }
}

/// The popover's web view outlives the popover.
///
/// SwiftUI is free to tear MenuBarExtra's content down when it closes, and
/// rebuilding a WKWebView means reloading and re-rendering the page on every
/// single open — the one surface where that delay is unmissable. One view,
/// created once, kept alive; the height callback is re-pointed instead.
@MainActor
private enum MenuWebView {
    static var view: WKWebView?
    static var onHeight: ((CGFloat) -> Void)?

    static func shared() -> WKWebView {
        if let view { return view }
        let created = WebHost.makeWebView(surface: "menu", transparent: true, onResize: { measured in
            onHeight?(measured)
        })
        view = created
        return created
    }
}

private struct MenuBarWebView: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        bindHeight()
        return MenuWebView.shared()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // A rebuilt representable carries a fresh binding; the long-lived web
        // view has to report into that one, not the one it launched with.
        bindHeight()
    }

    private func bindHeight() {
        let binding = $height
        MenuWebView.onHeight = { measured in
            // Never taller than the screen — content scrolls inside instead.
            let limit = (NSScreen.main?.visibleFrame.height ?? 900) - 60
            let clamped = min(max(measured, 120), limit)
            // Not during a layout pass: this arrives mid-render from the page.
            Task { @MainActor in
                if abs(binding.wrappedValue - clamped) > 0.5 { binding.wrappedValue = clamped }
            }
        }
    }
}
#endif
