#if canImport(WebKit) && canImport(AppKit)
import AppKit
import WebKit

/// Builds the web surfaces. One bundle in Contents/Resources/WebUI serves
/// every window; `?surface=` picks which root the page mounts, so a window is
/// a URL and a frame — nothing else.
@MainActor
enum WebHost {

    /// A window rendered by the web UI.
    struct Spec {
        let id: String
        let title: String
        let surface: String
        let size: NSSize
        let minSize: NSSize?

        static let settings = Spec(id: "websettings", title: "Settings", surface: "settings",
                                   size: NSSize(width: 1000, height: 720),
                                   minSize: NSSize(width: 840, height: 560))
        static let main = Spec(id: "main", title: "OpenAvatar", surface: "main",
                               size: NSSize(width: 1120, height: 760),
                               minSize: NSSize(width: 900, height: 600))
        static let call = Spec(id: "call", title: "Call notes", surface: "call",
                               size: NSSize(width: 720, height: 640),
                               minSize: NSSize(width: 520, height: 420))
        static let onboarding = Spec(id: "onboarding", title: "Welcome", surface: "onboarding",
                                     size: NSSize(width: 760, height: 600), minSize: nil)
    }

    /// A configured web view for one surface, already wired to the bridge and
    /// registered for host events.
    static func makeWebView(surface: String,
                            section: String? = nil,
                            transparent: Bool = false,
                            onResize: ((CGFloat) -> Void)? = nil,
                            onClose: (() -> Void)? = nil) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(WebUISchemeHandler(),
                                          forURLScheme: WebUISchemeHandler.scheme)
        let bridge = AppBridge(onResize: onResize, onClose: onClose)
        configuration.userContentController.addScriptMessageHandler(
            BridgeMessageHandler(bridge: bridge), contentWorld: .page, name: "avatar")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Transparent surfaces (the menu-bar popover) let the native vibrancy
        // show through and paint their own panel in CSS.
        webView.underPageBackgroundColor = transparent ? .clear : .windowBackgroundColor
        if #available(macOS 13.3, *) {
            webView.isInspectable = true   // right-click → Inspect Element
        }

        if WebUISchemeHandler.bundledRoot != nil {
            var url = "\(WebUISchemeHandler.scheme)://app/index.html?surface=\(surface)"
            if let section { url += "#\(section)" }
            webView.load(URLRequest(url: URL(string: url)!))
        } else {
            webView.loadHTMLString(missingAssetsHTML, baseURL: nil)
        }
        WebEventBus.shared.register(webView)
        return webView
    }

    static let missingAssetsHTML = """
    <html><body style="font-family: -apple-system; color: #666; display: grid; place-items: center; height: 100vh; margin: 0;">
    <div style="text-align: center;">
      <h3 style="color: #333;">Web UI missing from this build</h3>
      <p>Contents/Resources/WebUI wasn't packaged. Build it with:<br>
      <code>cd web &amp;&amp; npm ci &amp;&amp; npm run build</code>, then re-run scripts/make-app.sh.</p>
    </div></body></html>
    """
}

/// Opens and reuses the web-rendered windows.
@MainActor
final class WebWindowController {
    static let shared = WebWindowController()

    private var windows: [String: NSWindow] = [:]
    private var webViews: [String: WKWebView] = [:]

    func show(_ spec: WebHost.Spec, section: String? = nil, focus: Bool = true) {
        if let window = windows[spec.id] {
            if let section, let webView = webViews[spec.id] {
                webView.evaluateJavaScript("window.location.hash = '\(section)'")
            }
            if focus {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                window.orderFront(nil)
            }
            return
        }

        let id = spec.id
        let webView = WebHost.makeWebView(surface: spec.surface, section: section,
                                          onClose: { [weak self] in self?.close(id) })
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: spec.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = spec.title
        window.isReleasedWhenClosed = false
        if let minSize = spec.minSize { window.contentMinSize = minSize }
        window.center()
        // Remember the user's frame across launches (after center(), so a
        // saved frame wins over the default placement).
        window.setFrameAutosaveName("openavatar.window.\(spec.id)")
        window.contentView = webView

        windows[spec.id] = window
        webViews[spec.id] = webView
        if focus {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
    }

    func close(_ id: String) {
        windows[id]?.close()
        windows[id] = nil
        webViews[id] = nil
    }
}

/// JS → Swift: `webkit.messageHandlers.avatar.postMessage({method, params})`
/// returns a Promise; we resolve it with a JSON string (rejected with a
/// redacted error message on failure).
@MainActor
final class BridgeMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let bridge: AppBridge

    init(bridge: AppBridge) {
        self.bridge = bridge
    }

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
