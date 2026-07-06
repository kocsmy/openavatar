import Foundation

// MARK: - Audio & Transcript

enum AudioSource: String, Codable, Sendable {
    case mic      // the user ("You")
    case system   // everyone else on the call ("Others")
}

/// Mono 16 kHz 16-bit little-endian PCM.
struct AudioChunk: Sendable {
    let pcm: Data
    let source: AudioSource
    let t0: TimeInterval
    let t1: TimeInterval
}

struct TranscriptSegment: Codable, Identifiable, Sendable {
    var id = UUID()
    let text: String
    let t0: TimeInterval
    let t1: TimeInterval
    let source: AudioSource
    let confidence: Double

    var speakerLabel: String { source == .mic ? "You" : "Others" }
}

// MARK: - Decisions

enum DecisionIntent: String, Codable, CaseIterable, Sendable {
    case createTicket = "create_ticket"
    case codeChange = "code_change"
    case sendMessage = "send_message"
    case sendEmail = "send_email"
    case mergePR = "merge_pr"
    case other
}

enum DecisionStatus: String, Codable, Sendable {
    case detected, approved, edited, dismissed, executed, reverted
}

/// Reason picker used when dismissing (feeds the misfire log, PRD R2).
enum DismissReason: String, Codable, CaseIterable, Sendable {
    case wrongTranscription = "wrong_transcription"
    case wrongIntent = "wrong_intent"
    case notActionable = "not_actionable"
    case duplicate
    case other
}

struct Decision: Codable, Identifiable, Sendable {
    var id = UUID()
    var callID: UUID?
    var quote: String
    var intent: DecisionIntent
    var summary: String
    var assigneeHint: String?
    var confidence: Double
    var addressedToAssistant: Bool
    /// Which audio stream the trigger utterance came from. `.system` utterances
    /// never get autonomous destructive execution (spec §5.6).
    var source: AudioSource
    var status: DecisionStatus = .detected
    var dismissReason: DismissReason?
    var createdAt = Date()
}

// MARK: - Tools (shared between LLM layer and executors)

struct ToolSpec: Codable, Sendable {
    var name: String
    var description: String
    /// JSON-Schema object describing the parameters.
    var parameters: JSONValue
}

struct ToolCall: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var arguments: JSONValue
}

// MARK: - Actions

enum IntegrationID: String, Codable, CaseIterable, Identifiable, Sendable {
    case github, slack, linear, email
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .slack: return "Slack"
        case .linear: return "Linear"
        case .email: return "Email"
        }
    }
}

enum RiskClass: String, Codable, Comparable, Sendable {
    case read, draft, write, destructive

    private var rank: Int {
        switch self {
        case .read: return 0
        case .draft: return 1
        case .write: return 2
        case .destructive: return 3
        }
    }

    static func < (lhs: RiskClass, rhs: RiskClass) -> Bool { lhs.rank < rhs.rank }
}

struct ActionStep: Codable, Identifiable, Sendable {
    var id = UUID()
    var integration: IntegrationID
    var tool: String
    var arguments: JSONValue
    var riskClass: RiskClass

    /// Qualified tool name used as the trust-matrix row key, e.g. "github.merge_pr".
    var qualifiedTool: String { "\(integration.rawValue).\(tool)" }
}

struct ActionPreview: Codable, Sendable {
    var title: String
    /// Human-readable body: diff, message text, ticket fields, email body…
    var detail: String
}

struct ActionPlan: Codable, Identifiable, Sendable {
    var id = UUID()
    var decisionID: UUID
    var steps: [ActionStep]
    var riskClass: RiskClass
    var preview: ActionPreview
}

struct ActionResult: Codable, Identifiable, Sendable {
    var id = UUID()
    var integration: IntegrationID
    var tool: String
    var summary: String
    var url: String?
    /// Opaque handle the integration can use to revert (e.g. Slack ts+channel).
    /// Nil when the integration cannot natively revert this action.
    var revertHandle: JSONValue?
    var executedAt = Date()
}

struct IntegrationHealth: Sendable {
    var ok: Bool
    var message: String
}

// MARK: - Modes & routing

enum AssistantMode: String, Codable, CaseIterable, Sendable {
    case passive  // accumulate; post-call review
    case active   // execute immediately when directly addressed

    var displayName: String { rawValue.capitalized }
}

/// Per-task model routing (spec §4.3).
enum LLMTask: String, Codable, CaseIterable, Sendable {
    case detection   // cheap/fast
    case planning    // strong
    case summary     // cheap

    var displayName: String {
        switch self {
        case .detection: return "Decision detection"
        case .planning: return "Action planning & code edits"
        case .summary: return "Summaries"
        }
    }
}

// MARK: - Trust

enum TrustSetting: String, Codable, CaseIterable, Sendable {
    case askFirst = "ask_first"
    case autonomous

    var displayName: String { self == .askFirst ? "Ask first" : "Autonomous" }
}

/// Rows = qualified tool ("github.merge_pr"), columns = mode.
struct TrustMatrix: Codable, Sendable {
    private var cells: [String: TrustSetting] = [:]

    static func key(_ qualifiedTool: String, _ mode: AssistantMode) -> String {
        "\(qualifiedTool)#\(mode.rawValue)"
    }

    func setting(for qualifiedTool: String, mode: AssistantMode) -> TrustSetting {
        cells[Self.key(qualifiedTool, mode)] ?? .askFirst
    }

    mutating func set(_ setting: TrustSetting, for qualifiedTool: String, mode: AssistantMode) {
        cells[Self.key(qualifiedTool, mode)] = setting
    }

    /// Conservative defaults (spec §4.7): everything Ask first except
    /// comment_on_pr and create_issue in Active mode.
    static var defaults: TrustMatrix {
        var m = TrustMatrix()
        m.set(.autonomous, for: "github.comment_on_pr", mode: .active)
        m.set(.autonomous, for: "linear.create_issue", mode: .active)
        return m
    }
}

// MARK: - Errors

enum AppError: LocalizedError {
    case notConfigured(String)
    case http(status: Int, body: String)
    case parsing(String)
    case integration(String)
    case audio(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "Not configured: \(what)"
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(300))"
        case .parsing(let msg): return "Parse error: \(msg)"
        case .integration(let msg): return msg
        case .audio(let msg): return "Audio: \(msg)"
        case .cancelled: return "Cancelled"
        }
    }

    var isRetryable: Bool {
        if case .http(let status, _) = self {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }
}
