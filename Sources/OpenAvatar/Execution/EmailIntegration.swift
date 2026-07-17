import Foundation

/// Email plugin (spec §4.6): Gmail API via OAuth token OR generic SMTP with
/// app password. send_email is destructive by default (irreversible); sent
/// mail carries the 🤖 footer — enforced here.
struct EmailIntegration: ActionIntegration {
    let id: IntegrationID = .email

    struct Config: Sendable {
        var backend: EmailBackend
        var smtpHost: String
        var smtpPort: Int
        var smtpUsername: String
        var smtpPassword: String?
        var gmailAccessToken: String?
        var fromAddress: String
        var assistantName: String
        var userName: String
    }

    let config: Config
    var http = HTTPClient()

    var toolSpecs: [ToolSpec] {
        let emailProperties: JSONValue = .object([
            "to": .object(["type": "array", "items": .object(["type": "string"]),
                           "description": "recipient email addresses"]),
            "subject": .object(["type": "string"]),
            "body": .object(["type": "string", "description": "plain-text body"])
        ])
        return [
            ToolSpec(name: "draft_email",
                     description: "Prepare an email draft for review without sending it.",
                     parameters: .object(["type": "object", "properties": emailProperties,
                                          "required": .array(["to", "subject", "body"])])),
            ToolSpec(name: "send_email",
                     description: "Send an email. Destructive — irreversible once sent.",
                     parameters: .object(["type": "object", "properties": emailProperties,
                                          "required": .array(["to", "subject", "body"])]))
        ]
    }

    func riskClass(for tool: String) -> RiskClass {
        tool == "send_email" ? .destructive : .draft
    }

    func execute(_ call: ToolCall) async throws -> ActionResult {
        let to = (call.arguments["to"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let subject = call.arguments["subject"]?.stringValue ?? ""
        // 🤖 footer enforced in code (spec §4.6 / §5.3).
        let body = (call.arguments["body"]?.stringValue ?? "")
            + Attribution.emailFooter(assistantName: config.assistantName, userName: config.userName)

        switch call.name {
        case "draft_email":
            return ActionResult(integration: id, tool: call.name,
                                summary: "Drafted email to \(to.joined(separator: ", ")): \(subject)",
                                url: nil, revertHandle: nil)
        case "send_email":
            guard !to.isEmpty else { throw AppError.integration("send_email: no recipients") }
            // Recipients/from are transcript-derived; reject control characters
            // so they can't inject extra SMTP commands or spoofed headers.
            try EmailAddressGuard.validate(to + [config.fromAddress])
            switch config.backend {
            case .smtp:
                guard let password = config.smtpPassword, !config.smtpHost.isEmpty else {
                    throw AppError.notConfigured("SMTP host/password (Settings → Integrations → Email)")
                }
#if canImport(Network)
                let client = SMTPClient(host: config.smtpHost, port: UInt16(config.smtpPort))
                try await client.send(username: config.smtpUsername, password: password,
                                      from: config.fromAddress, to: to,
                                      subject: subject, body: body)
#else
                throw AppError.integration("SMTP requires macOS")
#endif
            case .gmail:
                try await sendViaGmail(to: to, subject: subject, body: body)
            }
            return ActionResult(integration: id, tool: call.name,
                                summary: "Sent email to \(to.joined(separator: ", ")): \(subject)",
                                url: nil, revertHandle: nil) // irreversible — no undo
        default:
            throw AppError.integration("Unknown Email tool: \(call.name)")
        }
    }

    private func sendViaGmail(to: [String], subject: String, body: String) async throws {
        guard let token = config.gmailAccessToken else {
            throw AppError.notConfigured("Gmail OAuth token (Settings → Integrations → Email)")
        }
        let raw = SMTPMessageEncoder.encode(from: config.fromAddress, to: to,
                                            subject: subject, body: body)
        _ = try await http.postJSON(
            URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!,
            headers: ["Authorization": "Bearer \(token)"],
            body: .object(["raw": .string(raw)]))
    }

    func healthCheck() async -> IntegrationHealth {
        switch config.backend {
        case .smtp:
            if config.smtpHost.isEmpty || config.smtpPassword == nil {
                return IntegrationHealth(ok: false, message: "SMTP host or app password missing")
            }
            return IntegrationHealth(ok: true, message: "SMTP configured for \(config.smtpUsername)")
        case .gmail:
            guard let token = config.gmailAccessToken else {
                return IntegrationHealth(ok: false, message: "Gmail OAuth token missing")
            }
            do {
                let json = try await http.getJSON(
                    URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!,
                    headers: ["Authorization": "Bearer \(token)"])
                return IntegrationHealth(ok: true, message: "Gmail: \(json["emailAddress"]?.stringValue ?? "?")")
            } catch {
                return IntegrationHealth(ok: false, message: Redactor.redact(error.localizedDescription))
            }
        }
    }
}

/// Guards against SMTP command / RFC 5322 header injection. Email addresses
/// flow from transcript-derived planner output, so a value containing CR/LF/NUL
/// could inject an extra `RCPT TO` command or a spoofed header (e.g. a hidden
/// `Bcc:`) and exfiltrate mail past the user's preview.
enum EmailAddressGuard {
    static func validate(_ addresses: [String]) throws {
        for address in addresses where address.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw AppError.integration("Invalid email address (contains control characters)")
        }
    }
}

/// RFC 5322 encoder shared by the Gmail path (base64url of the raw message).
enum SMTPMessageEncoder {
    static func encode(from: String, to: [String], subject: String, body: String) -> String {
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let message = """
        From: <\(from)>\r
        To: \(to.map { "<\($0)>" }.joined(separator: ", "))\r
        Subject: \(encodedSubject)\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(body.replacingOccurrences(of: "\n", with: "\r\n"))
        """
        return Data(message.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
