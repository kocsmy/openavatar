import XCTest
@testable import OpenAvatar

/// Spec §5.3 — the 🤖 marker is enforced in code, and secrets never survive
/// into logs.
final class AttributionTests: XCTestCase {

    func testPrefixIsApplied() {
        XCTAssertEqual(Attribution.prefix("Ship it"), "🤖 Ship it")
    }

    func testPrefixIsNotDuplicated() {
        XCTAssertEqual(Attribution.prefix("🤖 Ship it"), "🤖 Ship it")
    }

    func testEmailFooterNamesAssistantAndUser() {
        let footer = Attribution.emailFooter(assistantName: "Avatar", userName: "Sam")
        XCTAssertTrue(footer.contains("🤖"))
        XCTAssertTrue(footer.contains("Avatar"))
        XCTAssertTrue(footer.contains("on behalf of Sam"))
    }

    func testRedactorStripsTokens() {
        let input = """
        error with key sk-ant-abcdefghijklmnop123456 and token xoxp-1234567890-abcdef \
        and ghp_ABCDEFGHIJKLMNOPQRSTuvwxyz012345 and lin_api_abcdefghijklmnopqrst \
        and AIzaSyA-1234567890abcdefghijklmn and Bearer eyJhbGciOiJIUzI1NiJ9.payload
        """
        let output = Redactor.redact(input)
        XCTAssertFalse(output.contains("sk-ant-"))
        XCTAssertFalse(output.contains("xoxp-"))
        XCTAssertFalse(output.contains("ghp_"))
        XCTAssertFalse(output.contains("lin_api_"))
        XCTAssertFalse(output.contains("AIzaSy"))
        XCTAssertFalse(output.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testSendEmailIsDestructiveByDefault() {
        let email = EmailIntegration(config: .init(
            backend: .smtp, smtpHost: "", smtpPort: 465, smtpUsername: "",
            smtpPassword: nil, gmailAccessToken: nil, fromAddress: "",
            assistantName: "Avatar", userName: "Sam"))
        XCTAssertEqual(email.riskClass(for: "send_email"), .destructive)
        XCTAssertEqual(email.riskClass(for: "draft_email"), .draft)
    }

    func testMergePRIsAlwaysDestructive() {
        let github = GitHubIntegration(token: "x")
        XCTAssertEqual(github.riskClass(for: "merge_pr"), .destructive)
    }

    func testRiskClassOrdering() {
        XCTAssertTrue(RiskClass.read < .draft)
        XCTAssertTrue(RiskClass.draft < .write)
        XCTAssertTrue(RiskClass.write < .destructive)
        XCTAssertEqual([RiskClass.write, .destructive, .read].max(), .destructive)
    }
}
