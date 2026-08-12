#if canImport(WebKit) && canImport(AppKit)
import AppKit
import WebKit

/// The web-rendered Settings window: a WKWebView hosting the shadcn UI from
/// web/ (bundled into Contents/Resources/WebUI at packaging time), talking to
/// the app through SettingsBridge over a promise-returning message handler.
///
/// This is the "swap the settings page to a web UI" experiment: the rest of
/// the app stays native; if the web approach wins, more windows follow — the
/// same frontend could later move to Electron/Tauri unchanged.
@MainActor
final class WebSettingsWindowController: NSObject {
    static let shared = WebSettingsWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(
            BridgeMessageHandler(), contentWorld: .page, name: "avatar")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .windowBackgroundColor
        if #available(macOS 13.3, *) {
            webView.isInspectable = true   // right-click → Inspect Element for debugging
        }

        if let index = Bundle.main.url(forResource: "index", withExtension: "html",
                                       subdirectory: "WebUI") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(Self.missingAssetsHTML, baseURL: nil)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 840, height: 560)
        window.center()
        window.setFrameAutosaveName("openavatar.window.websettings")
        window.contentView = webView

        self.window = window
        self.webView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Deep-link a section (e.g. "integrations") — the page listens on the hash.
    func show(section: String) {
        show()
        webView?.evaluateJavaScript("window.location.hash = '\(section)'")
    }

    private static let missingAssetsHTML = """
    <html><body style="font-family: -apple-system; color: #666; display: grid; place-items: center; height: 100vh; margin: 0;">
    <div style="text-align: center;">
      <h3 style="color: #333;">Web settings UI missing from this build</h3>
      <p>Contents/Resources/WebUI wasn't packaged. Build it with:<br>
      <code>cd web && npm ci && npm run build</code>, then re-run scripts/make-app.sh.</p>
    </div></body></html>
    """
}

/// JS → Swift: `webkit.messageHandlers.avatar.postMessage({method, params})`
/// returns a Promise; we resolve it with a JSON string (rejected with a
/// redacted error message on failure).
@MainActor
private final class BridgeMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let bridge = SettingsBridge()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(nil, "Malformed bridge message")
            return
        }
        let params: JSONValue
        if let rawParams = body["params"],
           let data = try? JSONSerialization.data(withJSONObject: rawParams),
           let parsed = try? JSONValue.parse(data) {
            params = parsed
        } else {
            params = .object([:])
        }
        Task { @MainActor in
            do {
                let result = try await bridge.handle(method: method, params: params)
                replyHandler(result.encodedString(), nil)
            } catch {
                replyHandler(nil, Redactor.redact(error.localizedDescription))
            }
        }
    }
}
#endif
