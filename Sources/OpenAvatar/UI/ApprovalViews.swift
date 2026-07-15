import SwiftUI

extension Color {
    /// OpenAvatar's warm coral brand accent (matches the app icon).
    static let brand = Color(red: 0.82, green: 0.44, blue: 0.31)
}

/// Per-item approval card: preview (diff / message / ticket fields),
/// Approve / Edit / Dismiss (spec §4.8).
struct ApprovalCard: View {
    @EnvironmentObject var app: AppState
    let approval: PendingApproval
    @State private var isEditing = false
    @State private var editedJSON = ""
    @State private var editingStepID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                riskBadge
                Text(approval.plan.preview.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer()
            }

            ScrollView {
                Text(approval.plan.preview.detail)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            if isEditing {
                TextEditor(text: $editedJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(height: 100)
                HStack {
                    Button("Apply edit") { applyEdit() }.controlSize(.small)
                    Button("Cancel") { isEditing = false }.controlSize(.small)
                }
            } else {
                HStack {
                    Button("Approve") { app.approve(approval) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Edit") { beginEdit() }
                        .controlSize(.small)
                    Menu("Dismiss") {
                        ForEach(DismissReason.allCases, id: \.self) { reason in
                            Button(reason.displayName) {
                                app.dismiss(approval.decision, reason: reason)
                            }
                        }
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                    if approval.edited {
                        Text("edited").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var riskBadge: some View {
        Text(approval.plan.riskClass.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(badgeColor.opacity(0.2), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch approval.plan.riskClass {
        case .read: return .green
        case .draft: return .blue
        case .write: return .orange
        case .destructive: return .red
        }
    }

    private func beginEdit() {
        guard let step = approval.plan.steps.first else { return }
        editingStepID = step.id
        editedJSON = step.arguments.encodedString(pretty: true)
        isEditing = true
    }

    private func applyEdit() {
        guard let stepID = editingStepID,
              let parsed = try? JSONValue.parse(editedJSON) else { return }
        app.updateApproval(approval.id, editedArguments: parsed, stepID: stepID)
        isEditing = false
    }
}

/// Post-call review sheet (Passive mode, spec §4.8): every detected decision
/// with Approve / Edit / Dismiss; approved items are executed by the app.
struct PostCallReviewView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    private var isEmpty: Bool {
        app.detectedDecisions.isEmpty && app.pendingApprovals.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            if isEmpty {
                Spacer(minLength: 0)
                successState
                Spacer(minLength: 0)
            } else {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(app.pendingApprovals) { approval in
                            ApprovalCard(approval: approval)
                        }
                        ForEach(app.detectedDecisions) { decision in
                            reviewRow(decision)
                        }
                    }
                }
            }
            footer
        }
        .padding(20)
        .frame(width: 640, height: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Call review")
                .font(.title2.weight(.semibold))
            Text("\(settings.assistantName) detected these action items. Approve to execute — approved items are done by the app, not handed back to you as a to-do list.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Branded, centered "nothing to do" state.
    private var successState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.12)).frame(width: 96, height: 96)
                Circle().stroke(Color.brand.opacity(0.25), lineWidth: 1.5).frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.brand)
            }
            VStack(spacing: 8) {
                Text("You're all caught up")
                    .font(.title.weight(.semibold))
                Text("\(settings.assistantName) handled everything from this call — no action items left for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if app.isPlanning {
                ProgressView().controlSize(.small)
                Text("Planning…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") {
#if canImport(AppKit)
                WindowManager.shared.close(id: "review")
#endif
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func reviewRow(_ decision: Decision) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.summary).font(.callout)
                Text("“\(decision.quote)” — \(Int(decision.confidence * 100))% confident")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .opacity(decision.confidence < settings.confidenceThreshold ? 0.55 : 1)
            Spacer(minLength: 8)
            Button("Prepare") { app.prepare(decision) }.controlSize(.small)
            Menu {
                ForEach(DismissReason.allCases, id: \.self) { reason in
                    Button(reason.displayName) { app.dismiss(decision, reason: reason) }
                }
            } label: { Image(systemName: "xmark.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Dismiss")
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
