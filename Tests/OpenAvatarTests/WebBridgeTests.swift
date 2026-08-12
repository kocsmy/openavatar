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
