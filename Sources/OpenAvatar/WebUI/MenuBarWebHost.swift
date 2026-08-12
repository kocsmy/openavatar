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

private struct MenuBarWebView: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let binding = $height
        return WebHost.makeWebView(surface: "menu", transparent: true, onResize: { measured in
            // Never during a layout pass, and never taller than the screen.
            DispatchQueue.main.async {
                let limit = (NSScreen.main?.visibleFrame.height ?? 900) - 60
                binding.wrappedValue = min(max(measured, 120), limit)
            }
        })
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
