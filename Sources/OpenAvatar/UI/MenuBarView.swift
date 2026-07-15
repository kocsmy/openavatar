import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Menu-bar popover (spec §4.8): recording toggle, live "Detected this call"
/// list, pending approvals, executed actions with Undo.
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    enum PopoverTab: String, CaseIterable {
        case actions = "Actions"
        case transcript = "Transcript"
    }
    @State private var tab: PopoverTab = .actions

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()

            Picker("", selection: $tab) {
                ForEach(PopoverTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // A shared minimum height keeps both tabs the same size in their
            // empty/idle state, so switching tabs doesn't resize the menu-bar
            // window and leave a gap between the popover and the menu-bar icon.
            Group {
                if tab == .transcript {
                    LiveTranscriptView().padding(14)
                } else if popoverContent.needsScroll {
                    ScrollView { actionsContent.padding(14) }
                        .frame(height: PopoverLayout.maxContentHeight)
                } else {
                    actionsContent.padding(14)
                }
            }
            .frame(minHeight: PopoverLayout.minContentHeight, alignment: .top)

            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 420)
    }

    // MARK: Actions tab

    /// Single source of truth for what the Actions tab shows (see PopoverContent).
    var popoverContent: PopoverContent {
        PopoverContent(
            hasCallSuggestion: app.suggestedCallApp != nil && !app.isListening,
            hasError: app.lastError != nil,
            suggestions: app.proactiveSuggestions.count,
            approvals: app.pendingApprovals.count,
            detected: app.detectedDecisions.count,
            executed: app.executedActions.count)
    }

    @ViewBuilder private var actionsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(popoverContent.sections.enumerated()), id: \.offset) { _, kind in
                sectionView(kind)
            }
        }
    }

    @ViewBuilder private func sectionView(_ kind: PopoverSection) -> some View {
        switch kind {
        case .callSuggestion:
            callSuggestionBanner
        case .error:
            if let error = app.lastError { errorCard(error) }
        case .suggestions:
            section("Suggestions") {
                boundedRows(app.proactiveSuggestions, rowHeight: 72) { suggestionRow($0) }
            }
        case .approvals:
            section("Waiting for your approval") {
                ForEach(app.pendingApprovals) { ApprovalCard(approval: $0) }
            }
        case .detected:
            section("Detected this call") {
                boundedRows(app.detectedDecisions, rowHeight: 74) { DecisionRow(decision: $0) }
            }
        case .executed:
            section("Executed") {
                ForEach(app.executedActions.prefix(5)) { ExecutedActionRow(action: $0) }
            }
        case .empty:
            emptyState
        }
    }

    private var isEmptyState: Bool { popoverContent.isEmpty }

    @ViewBuilder private var callSuggestionBanner: some View {
        if let suggestion = app.suggestedCallApp, !app.isListening {
            HStack(spacing: 10) {
                Image(systemName: "phone.badge.waveform")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(suggestion) looks active").font(.caption.weight(.semibold))
                    Text("Start listening for this call?")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start") { app.startListening() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: app.isListening ? "waveform" : "moon.zzz")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(app.isListening
                 ? "Listening — decisions will appear here as they come up."
                 : "Not listening. Nothing is recorded until you start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button {
#if canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
#endif
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy full error")
                Button { app.clearErrors() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            // Full error, selectable and scrollable — never truncated.
            ScrollView {
                Text(error)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .padding(6)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            if app.errorLog.count > 1 {
                Text("\(app.errorLog.count) errors this session — full log in Settings → Data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func suggestionRow(_ suggestion: ProactiveSuggestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).font(.callout)
                Text(suggestion.rationale).font(.caption2)
                    .foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
            Button("Prepare") { app.accept(suggestion) }.controlSize(.small)
            Button { app.dismissSuggestion(suggestion) } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 11) {
            statusChip
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.assistantName).font(.headline)
                HStack(spacing: 5) {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    if app.isPlanning { ProgressView().controlSize(.mini) }
                    if app.isConsolidating {
                        Text("· saving").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button { app.toggleListening() } label: {
                Label(app.isListening ? "Stop" : "Listen",
                      systemImage: app.isListening ? "stop.fill" : "waveform")
                    .frame(minWidth: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isListening ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    private var statusChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(app.isListening ? Color.red.opacity(0.14) : Color.secondary.opacity(0.12))
                .frame(width: 38, height: 38)
            Image(systemName: app.isListening ? "waveform" : "waveform.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(app.isListening ? Color.red : Color.secondary)
        }
    }

    private var statusText: String {
        guard app.isListening else { return "Idle" }
        return app.systemAudioActive ? "Listening · mic + call audio" : "Listening · mic"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Mode").font(.caption).foregroundStyle(.secondary)
            Picker("Mode", selection: $settings.mode) {
                ForEach(AssistantMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 148)
            .help("Passive: review after the call. Active: executes immediately when you address \(settings.assistantName) by name.")

            Spacer()
            Button { openSettingsAndFocus() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit \(settings.assistantName)")
        }
    }

    /// Opens Settings and forces it to the front. As a menu-bar (accessory) app
    /// we aren't "active", so an already-open Settings window would otherwise
    /// stay buried behind other apps' windows — activate first, then raise it.
    private func openSettingsAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let settingsWindow = NSApp.windows.first {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
                    || $0.title == "OpenAvatar Settings"
            }
            settingsWindow?.makeKeyAndOrderFront(nil)
            settingsWindow?.orderFrontRegardless()
        }
    }

    @ViewBuilder private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            content()
        }
    }

    /// Shows up to `visibleCap` rows at full height; when there are more, the
    /// list is capped to that many rows and scrolls (a peek of the next row
    /// signals there's more).
    @ViewBuilder
    private func boundedRows<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, visibleCap: Int = 3, rowHeight: CGFloat,
        @ViewBuilder row: @escaping (Data.Element) -> RowContent
    ) -> some View where Data.Element: Identifiable {
        let rows = VStack(alignment: .leading, spacing: 8) {
            ForEach(data) { row($0) }
        }
        if data.count > visibleCap {
            ScrollView { rows }
                .frame(height: rowHeight * CGFloat(visibleCap))
        } else {
            rows
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.4)
    }
}

/// Deterministic estimate of the actions-tab content height, so the popover can
/// decide whether to scroll — without live geometry measurement (which regressed
/// and left a large blank area under short content). Pure and unit-tested.
enum PopoverLayout {
    static let maxContentHeight: CGFloat = 440
    /// Shared floor for both tabs' content so switching tabs in the idle state
    /// doesn't resize the menu-bar window (which leaves a gap under the icon).
    static let minContentHeight: CGFloat = 150

    struct Metrics: Equatable {
        var hasCallSuggestion: Bool
        var hasError: Bool
        var suggestions: Int
        var approvals: Int
        var detected: Int
        var executed: Int
        var isEmpty: Bool

        /// Rough height in points; only needs to be right about the scroll cutoff.
        var estimatedHeight: CGFloat {
            if isEmpty { return 150 }
            var h: CGFloat = 20                                   // section spacing overhead
            if hasCallSuggestion { h += 64 }
            if hasError { h += 156 }
            if suggestions > 0 { h += 24 + CGFloat(min(suggestions, 3)) * 72 }
            h += CGFloat(approvals) * 244                        // approval cards are tall
            if detected > 0 { h += 24 + CGFloat(min(detected, 3)) * 74 }
            if executed > 0 { h += 24 + CGFloat(min(executed, 5)) * 44 }
            return h
        }

        var needsScroll: Bool { estimatedHeight > PopoverLayout.maxContentHeight }
    }
}

/// The ordered sections the Actions tab renders, in presentation order.
enum PopoverSection: String, Equatable {
    case callSuggestion, error, suggestions, approvals, detected, executed, empty
}

/// Pure view-model for the Actions tab: which sections show, whether the empty
/// state applies, and whether the content must scroll. The view renders straight
/// from this, so `PopoverContentTests` snapshots exactly what the user sees.
struct PopoverContent: Equatable {
    let sections: [PopoverSection]
    let isEmpty: Bool
    let needsScroll: Bool

    init(hasCallSuggestion: Bool, hasError: Bool,
         suggestions: Int, approvals: Int, detected: Int, executed: Int) {
        let empty = !hasError && suggestions == 0 && approvals == 0
            && detected == 0 && executed == 0
        var s: [PopoverSection] = []
        if hasCallSuggestion { s.append(.callSuggestion) }
        if hasError { s.append(.error) }
        if suggestions > 0 { s.append(.suggestions) }
        if approvals > 0 { s.append(.approvals) }
        if detected > 0 { s.append(.detected) }
        if executed > 0 { s.append(.executed) }
        if empty { s.append(.empty) }
        self.sections = s
        self.isEmpty = empty
        self.needsScroll = PopoverLayout.Metrics(
            hasCallSuggestion: hasCallSuggestion, hasError: hasError,
            suggestions: suggestions, approvals: approvals,
            detected: detected, executed: executed, isEmpty: empty).needsScroll
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
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(belowThreshold ? Color.secondary : Color.accentColor)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.summary)
                    .font(.callout)
                    .foregroundStyle(belowThreshold ? .secondary : .primary)
                Text("“\(decision.quote)”")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
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
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Dismiss")
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
