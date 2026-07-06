import Foundation
#if canImport(Network)
import Network

/// Minimal SMTP client over implicit TLS (port 465) with AUTH LOGIN — enough
/// for Gmail/Fastmail-style app passwords (spec §4.6 email backend).
final class SMTPClient {
    private let host: String
    private let port: UInt16
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.openavatar.smtp")

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: .tls)
    }

    func send(username: String, password: String, from: String,
              to recipients: [String], subject: String, body: String) async throws {
        try await connect()
        defer { connection.cancel() }

        try await expect("220", after: nil)
        try await expect("250", after: "EHLO openavatar.local")
        try await expect("334", after: "AUTH LOGIN")
        try await expect("334", after: Data(username.utf8).base64EncodedString())
        try await expect("235", after: Data(password.utf8).base64EncodedString())
        try await expect("250", after: "MAIL FROM:<\(from)>")
        for rcpt in recipients {
            try await expect("250", after: "RCPT TO:<\(rcpt)>")
        }
        try await expect("354", after: "DATA")

        let message = Self.rfc5322(from: from, to: recipients, subject: subject, body: body)
        try await expect("250", after: message + "\r\n.")
        _ = try? await roundTrip("QUIT")
    }

    static func rfc5322(from: String, to: [String], subject: String, body: String) -> String {
        let date = { let f = DateFormatter()
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date()) }()
        // Dot-stuff body lines per RFC 5321 §4.5.2.
        let stuffed = body.replacingOccurrences(of: "\n", with: "\r\n")
            .components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        return """
        From: <\(from)>\r
        To: \(to.map { "<\($0)>" }.joined(separator: ", "))\r
        Subject: \(encodedSubject)\r
        Date: \(date)\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        \(stuffed)
        """
    }

    // MARK: Wire plumbing

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: AppError.integration("SMTP connect failed: \(error.localizedDescription)"))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func expect(_ code: String, after command: String?) async throws {
        let reply = try await roundTrip(command)
        guard reply.hasPrefix(code) else {
            throw AppError.integration("SMTP expected \(code), got: \(Redactor.redact(String(reply.prefix(200))))")
        }
    }

    private func roundTrip(_ command: String?) async throws -> String {
        if let command {
            try await sendLine(command)
        }
        return try await receiveLine()
    }

    private func sendLine(_ line: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AppError.integration("SMTP send failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveLine() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: AppError.integration("SMTP receive failed: \(error.localizedDescription)"))
                } else if let data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: AppError.integration("SMTP connection closed"))
                }
            }
        }
    }
}
#endif
