import SwiftUI

/// Spec §4.7 — rows = action tool per integration, columns = mode,
/// cell = Ask first | Autonomous. Destructive tools can only be set
/// Autonomous after ≥10 clean approved executions (graduated autonomy).
struct TrustMatrixTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    /// Dynamic rows from manifest + MCP integrations (native rows below are
    /// curated). Refreshed on each render so new manifests/servers show up.
    private var dynamicRows: [(qualified: String, risk: RiskClass)] {
        IntegrationRegistry.shared.dynamicTrustRows()
    }

    /// Native tools (shown even when the integration isn't connected yet, so
    /// users can pre-configure policy).
    private static let rows: [(qualified: String, risk: RiskClass)] = [
        ("github.create_branch", .write),
        ("github.commit_changes", .write),
        ("github.open_pr", .write),
        ("github.comment_on_pr", .write),
        ("github.merge_pr", .destructive),
        ("github.revert_pr", .write),
        ("slack.post_message", .write),
        ("slack.post_thread_reply", .write),
        ("slack.send_dm", .write),
        ("linear.create_issue", .write),
        ("linear.update_issue", .write),
        ("linear.comment_on_issue", .write),
        ("linear.assign_issue", .write),
        ("email.draft_email", .draft),
        ("email.send_email", .destructive)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trust ladder")
                .font(.headline)
            Text("Per action type, choose whether \(settings.assistantName) asks first or acts autonomously. Destructive actions (red) unlock Autonomous only after \(TrustPolicyEngine.graduationThreshold) approved executions without a revert or edit. Requests spoken by other call participants always require approval for destructive actions, regardless of this matrix.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Action").frame(width: 220, alignment: .leading)
                Text("Passive").frame(width: 160)
                Text("Active").frame(width: 160)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Self.rows, id: \.qualified) { row in
                        matrixRow(row.qualified, risk: row.risk)
                    }
                    let extra = dynamicRows
                    if !extra.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("From manifests & MCP servers")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(extra, id: \.qualified) { row in
                            matrixRow(row.qualified, risk: row.risk)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func matrixRow(_ qualified: String, risk: RiskClass) -> some View {
        let graduated = app.trust.canGraduate(qualifiedTool: qualified, riskClass: risk)
        return HStack {
            HStack(spacing: 6) {
                Circle().fill(risk == .destructive ? Color.red : Color.orange.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(qualified).font(.system(.caption, design: .monospaced))
            }
            .frame(width: 220, alignment: .leading)

            ForEach(AssistantMode.allCases, id: \.self) { mode in
                Picker("", selection: binding(qualified, mode: mode)) {
                    Text("Ask first").tag(TrustSetting.askFirst)
                    Text("Autonomous").tag(TrustSetting.autonomous)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .disabled(risk == .destructive && !graduated)
                .help(risk == .destructive && !graduated
                      ? "Needs \(TrustPolicyEngine.graduationThreshold) approved, unreverted executions before Autonomous unlocks."
                      : "")
            }
        }
    }

    private func binding(_ qualified: String, mode: AssistantMode) -> Binding<TrustSetting> {
        Binding(get: { settings.trustMatrix.setting(for: qualified, mode: mode) },
                set: { newValue in
            // Explicit user action is the only path that changes trust (spec §5.4).
            var matrix = settings.trustMatrix
            matrix.set(newValue, for: qualified, mode: mode)
            settings.trustMatrix = matrix
        })
    }
}
