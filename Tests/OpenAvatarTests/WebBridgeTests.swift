import XCTest
@testable import OpenAvatar

/// The Swift half of the web settings bridge. The TypeScript half
/// (web/src/lib/types.ts) hard-codes these names — a drift here breaks the
/// settings window silently, so the contract is pinned by tests.
final class WebBridgeTests: XCTestCase {

    @MainActor func testSecretSlotsMatchTheWebContract() {
        let names = SettingsBridge.secretKeys.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate secret slot names")
        // Must equal the SecretKey union in web/src/lib/types.ts.
        XCTAssertEqual(Set(names), [
            "anthropic", "openai", "gemini", "cloudSTT", "github", "slack",
            "linear", "smtp", "gmail", "googleClientSecret"
        ])
    }

    @MainActor func testEverySecretSlotHasAKeychainKey() {
        // Each logical slot maps to a distinct Keychain entry.
        let keys = SettingsBridge.secretKeys.map(\.key)
        XCTAssertEqual(keys.count, Set(keys.map(\.rawValue)).count)
    }

#if canImport(WebKit)
    func testSchemeHandlerServesOnlyFilesInsideTheWebUIRoot() throws {
        // Regression (v1.31.0): file:// couldn't load Vite's module scripts at
        // all — blank window. The custom scheme serves them; it must never
        // serve anything OUTSIDE the bundled WebUI folder.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webui-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("js".utf8).write(to: root.appendingPathComponent("assets/app.js"))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNotNil(WebUISchemeHandler.resolve(path: "/index.html", under: root))
        XCTAssertNotNil(WebUISchemeHandler.resolve(path: "/", under: root))
        XCTAssertNotNil(WebUISchemeHandler.resolve(path: "/assets/app.js", under: root))
        XCTAssertNil(WebUISchemeHandler.resolve(path: "/../outside.txt", under: root))
        XCTAssertNil(WebUISchemeHandler.resolve(path: "/assets/../../outside.txt", under: root))
        XCTAssertNil(WebUISchemeHandler.resolve(path: "/missing.js", under: root))
    }

    func testSchemeHandlerMimeTypes() {
        // Wrong MIME on a module script is another silent blank window.
        XCTAssertEqual(WebUISchemeHandler.mimeType(forExtension: "js"), "text/javascript")
        XCTAssertEqual(WebUISchemeHandler.mimeType(forExtension: "html"), "text/html")
        XCTAssertEqual(WebUISchemeHandler.mimeType(forExtension: "css"), "text/css")
        XCTAssertEqual(WebUISchemeHandler.mimeType(forExtension: "svg"), "image/svg+xml")
    }
#endif

    @MainActor func testTrustRowsKeepTheDestructiveOnesDestructive() {
        let rows = SettingsBridge.nativeTrustRows
        XCTAssertEqual(Set(rows.map(\.qualified)).count, rows.count, "duplicate trust rows")
        // The graduation lock (10 clean executions) hangs off these — they
        // must never quietly become "write".
        XCTAssertTrue(rows.contains { $0.qualified == "github.merge_pr" && $0.risk == .destructive })
        XCTAssertTrue(rows.contains { $0.qualified == "email.send_email" && $0.risk == .destructive })
        XCTAssertTrue(rows.contains { $0.qualified == "email.draft_email" && $0.risk == .draft })
    }
}
