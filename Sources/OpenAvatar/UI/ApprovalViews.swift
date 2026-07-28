import SwiftUI

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

