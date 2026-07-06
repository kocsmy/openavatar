import SwiftUI

/// Menu-bar popover (spec §4.8): recording toggle, live "Detected this call"
/// list, pending approvals, executed actions with Undo.
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if !app.pendingApprovals.isEmpty {
                sectionTitle("Waiting for your approval")
                ForEach(app.pendingApprovals) { approval in
                    ApprovalCard(approval: approval)
                }
            }

            if !app.detectedDecisions.isEmpty {
                sectionTitle("Detected this call")
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(app.detectedDecisions) { decision in
                            DecisionRow(decision: decision)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if !app.executedActions.isEmpty {
                sectionTitle("Executed")
                ForEach(app.executedActions.prefix(5)) { action in
                    ExecutedActionRow(action: action)
                }
            }

            if app.detectedDecisions.isEmpty && app.pendingApprovals.isEmpty
                && app.executedActions.isEmpty && app.lastError == nil {
                Text(app.isListening
                     ? "Listening… decisions will appear here."
                     : "Not listening. Nothing is recorded until you start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.assistantName).font(.headline)
                HStack(spacing: 4) {
                    Circle()
                        .fill(app.isListening ? Color.red : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(app.isListening
                         ? (app.systemAudioActive ? "Recording mic + system audio" : "Recording mic")
                         : "Idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if app.isPlanning {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            Spacer()
            Toggle(isOn: Binding(get: { app.isListening },
                                 set: { _ in app.toggleListening() })) {
                Text(app.isListening ? "Stop" : "Listen")
            }
            .toggleStyle(.button)
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let suggestion = app.suggestedCallApp, !app.isListening {
                Label("\(suggestion) looks like it's running — start listening?",
                      systemImage: "phone.badge.waveform")
                    .font(.caption)
            }
            HStack {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(AssistantMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .help("Passive: review after the call. Active: executes immediately when you address \(settings.assistantName) by name.")

                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct DecisionRow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore
    let decision: Decision

    /// Below the confidence threshold → greyed out, never auto-executed (§4.4).
    private var belowThreshold: Bool { decision.confidence < settings.confidenceThreshold }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(belowThreshold ? .tertiary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.summary)
                    .font(.callout)
                    .foregroundStyle(belowThreshold ? .secondary : .primary)
                Text("“\(decision.quote)”")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Prepare") { app.prepare(decision) }
                .controlSize(.small)
            Menu {
                ForEach(DismissReason.allCases, id: \.self) { reason in
                    Button(reasonLabel(reason)) { app.dismiss(decision, reason: reason) }
                }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .opacity(belowThreshold ? 0.6 : 1)
    }

    private var icon: String {
        switch decision.intent {
        case .createTicket: return "checklist"
        case .codeChange: return "chevron.left.forwardslash.chevron.right"
        case .sendMessage: return "bubble.left"
        case .sendEmail: return "envelope"
        case .mergePR: return "arrow.triangle.merge"
        case .other: return "sparkle"
        }
    }

    private func reasonLabel(_ reason: DismissReason) -> String {
        switch reason {
        case .wrongTranscription: return "Wrong transcription"
        case .wrongIntent: return "Wrong intent"
        case .notActionable: return "Not actionable"
        case .duplicate: return "Duplicate"
        case .other: return "Dismiss"
        }
    }
}

struct ExecutedActionRow: View {
    @EnvironmentObject var app: AppState
    let action: ExecutedAction

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: action.undone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(action.undone ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.result.summary).font(.caption).lineLimit(2)
                if let url = action.result.url, let link = URL(string: url) {
                    Link(url, destination: link).font(.caption2).lineLimit(1)
                }
            }
            Spacer()
            if action.canUndo {
                Button("Undo") { app.undo(action) }
                    .controlSize(.small)
            }
        }
    }
}
