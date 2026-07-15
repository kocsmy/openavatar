import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Network)
import Network
#endif
#if canImport(AppKit)
import AppKit
#endif

enum GoogleOAuthError: LocalizedError {
    case notConfigured
    case userCancelled
    case listenerFailed(String)
    case tokenExchangeFailed(String)
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Calendar isn't set up. Add your OAuth client ID and secret in Settings → Calendar."
        case .userCancelled:
            return "Google sign-in was cancelled."
        case .listenerFailed(let m): return "Local sign-in listener failed: \(m)"
        case .tokenExchangeFailed(let m): return "Google token exchange failed: \(m)"
        case .unsupportedPlatform: return "Google sign-in requires macOS."
        }
    }
}

/// OAuth 2.0 for an installed app (Google "Desktop app" client), using PKCE and
/// a loopback redirect — the current best practice for native apps. The app
/// opens the system browser, Google redirects back to a short-lived local HTTP
/// listener on 127.0.0.1, and the captured authorization code is exchanged for
/// tokens. The refresh token lives in the Keychain; access tokens are minted on
/// demand and cached in memory until they expire.
///
/// No secret is embedded in the binary: the user supplies their own client ID
/// and secret from their Google Cloud project (matching the app's BYO-credential
/// model for every other integration).
actor GoogleOAuth {
    static let shared = GoogleOAuth()

    private let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private var cachedAccessToken: String?
    private var accessTokenExpiry: Date = .distantPast

    private var clientID: String { SettingsStore.shared.googleClientID.trimmingCharacters(in: .whitespaces) }
    private var clientSecret: String? { KeychainStore.shared.get(.googleClientSecret) }

    nonisolated var isConnected: Bool {
        KeychainStore.shared.get(.googleCalendarRefreshToken) != nil
    }

    nonisolated var isConfigured: Bool {
        !SettingsStore.shared.googleClientID.trimmingCharacters(in: .whitespaces).isEmpty
            && KeychainStore.shared.get(.googleClientSecret) != nil
    }

    /// Interactive connect: opens the browser, captures the redirect, stores the
    /// refresh token. Throws with a user-facing message on any failure.
    func connect() async throws {
        guard !clientID.isEmpty, let secret = clientSecret, !secret.isEmpty else {
            throw GoogleOAuthError.notConfigured
        }
#if canImport(Network) && canImport(CryptoKit) && canImport(AppKit)
        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Self.codeChallenge(for: verifier)

        let listener = LoopbackRedirectListener()
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        guard let authURL = comps.url else {
            await listener.cancel()
            throw GoogleOAuthError.listenerFailed("could not build auth URL")
        }

        await MainActor.run { NSWorkspace.shared.open(authURL) }

        let code: String
        do {
            code = try await listener.waitForCode(timeout: 180)
        } catch {
            await listener.cancel()
            throw error
        }
        await listener.cancel()

        try await exchangeCode(code, redirectURI: redirectURI, verifier: verifier, secret: secret)
#else
        throw GoogleOAuthError.unsupportedPlatform
#endif
    }

    func disconnect() {
        KeychainStore.shared.delete(.googleCalendarRefreshToken)
        cachedAccessToken = nil
        accessTokenExpiry = .distantPast
    }

    /// A valid access token, refreshing via the stored refresh token if needed.
    func accessToken() async throws -> String {
        if let token = cachedAccessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refresh = KeychainStore.shared.get(.googleCalendarRefreshToken) else {
            throw GoogleOAuthError.notConfigured
        }
        guard !clientID.isEmpty, let secret = clientSecret else {
            throw GoogleOAuthError.notConfigured
        }
        let form = [
            "client_id": clientID,
            "client_secret": secret,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ]
        let json = try await postForm(form)
        guard let token = json["access_token"]?.stringValue else {
            throw GoogleOAuthError.tokenExchangeFailed(Redactor.redact(json.encodedString()))
        }
        cache(token: token, expiresIn: json["expires_in"]?.numberValue ?? 3600)
        return token
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String, redirectURI: String, verifier: String, secret: String) async throws {
        let form = [
            "client_id": clientID,
            "client_secret": secret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        let json = try await postForm(form)
        guard let access = json["access_token"]?.stringValue else {
            throw GoogleOAuthError.tokenExchangeFailed(Redactor.redact(json.encodedString()))
        }
        if let refresh = json["refresh_token"]?.stringValue {
            KeychainStore.shared.set(refresh, for: .googleCalendarRefreshToken)
        }
        cache(token: access, expiresIn: json["expires_in"]?.numberValue ?? 3600)
    }

    private func cache(token: String, expiresIn: Double) {
        cachedAccessToken = token
        accessTokenExpiry = Date().addingTimeInterval(expiresIn)
    }

    private func postForm(_ fields: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: tokenEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleOAuthError.tokenExchangeFailed("HTTP \(status): "
                + Redactor.redact(String(data: data, encoding: .utf8) ?? ""))
        }
        return try JSONValue.parse(data)
    }

    // MARK: - PKCE helpers

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let ev = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(ev)"
        }.joined(separator: "&")
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func codeChallenge(for verifier: String) -> String {
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
#else
        return verifier   // (plain) — only reached on platforms without CryptoKit
#endif
    }
}

#if canImport(Network)
/// A one-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect,
/// extracts `?code=`, and shows the user a "you can close this tab" page.
actor LoopbackRedirectListener {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    // nonisolated so the Network callbacks (which run off-actor) can read it.
    private nonisolated let queue = DispatchQueue(label: "com.openavatar.oauth.loopback")

    /// Binds an ephemeral loopback port and returns it.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 0)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(on: connection)
        }

        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        cont.resume(returning: port)
                    } else {
                        cont.resume(throwing: GoogleOAuthError.listenerFailed("no port assigned"))
                    }
                case .failed(let error):
                    cont.resume(throwing: GoogleOAuthError.listenerFailed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Awaits the authorization code, or throws on timeout / cancel.
    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitCode() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw GoogleOAuthError.userCancelled
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func awaitCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            if finished { cont.resume(throwing: GoogleOAuthError.userCancelled); return }
            continuation = cont
        }
    }

    func cancel() {
        listener?.cancel()
        listener = nil
        if !finished, let cont = continuation {
            finished = true
            continuation = nil
            cont.resume(throwing: GoogleOAuthError.userCancelled)
        }
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8) {
                let code = Self.parseCode(fromRequestLine: request)
                let body = code == nil
                    ? "OpenAvatar: no authorization code found. You can close this tab."
                    : "OpenAvatar is connected to Google Calendar. You can close this tab and return to the app."
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                Task { await self.deliver(code) }
            } else {
                connection.cancel()
            }
        }
    }

    private func deliver(_ code: String?) {
        guard !finished else { return }
        finished = true
        let cont = continuation
        continuation = nil
        if let code {
            cont?.resume(returning: code)
        } else {
            cont?.resume(throwing: GoogleOAuthError.userCancelled)
        }
    }

    /// Pulls the `code` query parameter from the first request line
    /// ("GET /?code=...&scope=... HTTP/1.1").
    static func parseCode(fromRequestLine request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first
        else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])
        guard let comps = URLComponents(string: "http://127.0.0.1\(path)") else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }
}
#endif
