#if canImport(WebKit)
import Foundation
import WebKit

/// Serves Contents/Resources/WebUI under openavatar-ui://app/… with real HTTP
/// responses and MIME types.
///
/// Not a detail: Vite emits `<script type="module" crossorigin>`, and WebKit
/// refuses CORS-mode module loads from file:// URLs — v1.31.0 shipped with
/// loadFileURL and rendered a blank window, because the HTML parsed but no
/// script ever ran. A scheme handler answers with responses modules accept.
final class WebUISchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "openavatar-ui"

    /// The bundled web app, if this build packaged one.
    static var bundledRoot: URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("WebUI", isDirectory: true),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
        else { return nil }
        return root
    }

    /// Resolve a request path against the WebUI root; nil for anything that
    /// escapes it or doesn't exist.
    static func resolve(path: String, under root: URL) -> URL? {
        var relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if relative.isEmpty { relative = "index.html" }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/")
                || file.path == root.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return file
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "woff", "woff2": return "font/woff2"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let root = Self.bundledRoot,
              let file = Self.resolve(path: url.path, under: root),
              let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(AppError.integration(
                "WebUI asset not found: \(urlSchemeTask.request.url?.path ?? "?")"))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(forExtension: file.pathExtension),
                "Content-Length": "\(data.count)",
                // Vite marks module scripts crossorigin; answer CORS properly.
                "Access-Control-Allow-Origin": "*"
            ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
#endif
