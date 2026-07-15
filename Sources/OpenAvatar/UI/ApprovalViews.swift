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

    /// One editable argument. String values edit as plain text; anything else
    /// (arrays, numbers, nested objects) edits as JSON so nothing is lost.
    struct EditField: Identifiable {
        let id = UUID()
        let key: String
        var value: String
        let isString: Bool
        let multiline: Bool
    }

    @State private var isEditing = false
    @State private var editingStepID: UUID?
    @State private var fields: [EditField] = []
    @State private var editError: String?

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
                editor
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
                    .menuIndicator(.hidden)
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($fields) { $field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.key)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if field.multiline {
                        TextEditor(text: $field.value)
                            .font(.callout)
                            .frame(height: 68)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .stroke(.quaternary, lineWidth: 1))
                    } else {
                        TextField(field.key, text: $field.value)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            if let editError {
                Text(editError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Save changes") { applyEdit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { isEditing = false }
                    .controlSize(.small)
            }
        }
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

    private static let longKeys: Set<String> =
        ["body", "description", "message", "detail", "text", "content", "comment", "notes"]

    private func beginEdit() {
        guard let step = approval.plan.steps.first,
              let object = step.arguments.objectValue else { return }
        editingStepID = step.id
        editError = nil
        fields = object.sorted { $0.key < $1.key }.map { key, value in
            if let s = value.stringValue {
                let multiline = s.count > 48 || s.contains("\n") || Self.longKeys.contains(key.lowercased())
                return EditField(key: key, value: s, isString: true, multiline: multiline)
            } else {
                // Non-string: edit as JSON so arrays/numbers survive round-trip.
                return EditField(key: key, value: value.encodedString(), isString: false, multiline: true)
            }
        }
        isEditing = true
    }

    private func applyEdit() {
        guard let stepID = editingStepID,
              let step = approval.plan.steps.first(where: { $0.id == stepID }),
              var object = step.arguments.objectValue else { return }
        for field in fields {
            if field.isString {
                object[field.key] = .string(field.value)
            } else {
                // Re-parse edited JSON for non-string fields; report a clear error
                // instead of silently dropping the change.
                guard let parsed = try? JSONValue.parse(field.value) else {
                    editError = "“\(field.key)” isn't valid — check the format and try again."
                    return
                }
                object[field.key] = parsed
            }
        }
        app.updateApproval(approval.id, editedArguments: .object(object), stepID: stepID)
        isEditing = false
    }
}

/// Post-call review sheet (Passive mode, spec §4.8): every detected decision
/// with Approve / Edit / Dismiss; approved items are executed by the app.
struct PostCallReviewView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    @State private var showHandled = false
    @State private var handled: [Decision] = []

    private var isEmpty: Bool {
        app.detectedDecisions.isEmpty && app.pendingApprovals.isEmpty && app.pendingFollowUps.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            if isEmpty && !showHandled {
                Spacer(minLength: 0)
                successState
                Spacer(minLength: 0)
            } else {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !app.pendingFollowUps.isEmpty {
                            followUpsSection
                        }
                        ForEach(app.pendingApprovals) { approval in
                            ApprovalCard(approval: approval)
                        }
                        ForEach(app.detectedDecisions) { decision in
                            reviewRow(decision)
                        }
                        if showHandled {
                            handledSection
                        }
                    }
                }
            }
            footer
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .onAppear { handled = app.handledDecisions() }
    }

    // MARK: Handled history ("what happened")

    private var handledSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HANDLED ON THIS CALL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            if handled.isEmpty {
                Text("Nothing has been handled on this call yet.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(handled) { decision in
                handledRow(decision)
            }
        }
    }

    private func handledRow(_ decision: Decision) -> some View {
        let style = Self.statusStyle(decision.status)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.summary).font(.callout).foregroundStyle(.secondary)
                Text("“\(decision.quote)”")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(style.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(style.color)
                    if decision.status == .dismissed, let reason = decision.dismissReason {
                        Text("· \(reason.displayName)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(8)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    static func statusStyle(_ status: DecisionStatus) -> (label: String, icon: String, color: Color) {
        switch status {
        case .approved: return ("Approved", "checkmark.circle.fill", .green)
        case .edited: return ("Edited & approved", "pencil.circle.fill", .orange)
        case .executed: return ("Executed", "bolt.circle.fill", .green)
        case .dismissed: return ("Dismissed", "xmark.circle.fill", .secondary)
        case .reverted: return ("Undone", "arrow.uturn.backward.circle.fill", .orange)
        case .detected: return ("Pending", "circle", .secondary)
        }
    }

    private var followUpsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Follow-ups — remind me later", systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brand)
            ForEach(app.pendingFollowUps) { followUp in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Color.brand)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(followUp.title).font(.callout)
                        Text(FollowUpFormatter.due(followUp.dueAt))
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        if let quote = followUp.quote, !quote.isEmpty {
                            Text("“\(quote)”").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Remind me") { app.confirmFollowUp(followUp) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button {
                        app.dismissFollowUp(followUp)
                    } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Don't remind me")
                }
                .padding(8)
                .background(Color.brand.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
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
            Button {
                handled = app.handledDecisions()   // refresh, incl. just-now actions
                showHandled.toggle()
            } label: {
                Label(showHandled ? "Hide handled" : "Show handled (\(handled.count))",
                      systemImage: showHandled ? "eye.slash" : "clock.arrow.circlepath")
            }
            .controlSize(.small)
            .help("See what was already approved, dismissed, or executed on this call")
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
