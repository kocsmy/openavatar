import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Menu-bar popover, Granola-style: recording toggle, the next meetings, the
/// last call's pending actions, and quick menu rows. The live transcript
/// lives in the call window (CallNotesWindowView), not here.
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()

            // The content region is one CONSTANT height in every state, so the
            // menu-bar window has exactly one size and never resizes while
            // open. MenuBarExtra windows resize unreliably when content
            // changes mid-open — suggestions and the call banner arrive
            // asynchronously and used to overlap the footer. Whatever doesn't
            // fit scrolls inside this region instead.
            Group {
                if popoverContent.isEmpty {
                    actionsContent.padding(14)   // empty state centers itself
                } else {
                    ScrollView { actionsContent.padding(14) }
                }
            }
            .frame(height: PopoverLayout.contentHeight, alignment: .top)
            .clipped()   // even a mis-sized child can never draw over the footer

            Divider()
            menuRows
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 420)
        .onAppear { app.refreshUpcomingEvents() }
    }

    // MARK: Content

    /// Single source of truth for what the content region shows (see PopoverContent).
    var popoverContent: PopoverContent {
        PopoverContent(
            hasCallSuggestion: app.suggestedCallApp != nil && !app.isListening,
            hasError: app.lastError != nil,
            upcoming: upcomingSoon.count,
            suggestions: app.proactiveSuggestions.count,
            approvals: app.pendingApprovals.count,
            detected: app.detectedDecisions.count,
            executed: app.executedActions.count)
    }

    /// Today's and tomorrow's meetings that haven't ended yet (max 4).
    private var upcomingSoon: [CalendarEvent] {
        let now = Date()
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))
        else { return [] }
        return Array(app.upcomingEvents
            .filter { event in
                guard let start = event.start else { return false }
                if let end = event.end, end < now { return false }
                return start < cutoff
            }
            .prefix(4))
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
        case .upcoming:
            section("Coming up") {
                ForEach(upcomingSoon) { event in upcomingRow(event) }
            }
        case .suggestions:
            section("Suggestions") {
                boundedRows(app.proactiveSuggestions, rowHeight: 72) { suggestionRow($0) }
            }
        case .approvals:
            section("Waiting for your approval") {
                ForEach(app.pendingApprovals) { ApprovalCard(approval: $0) }
            }
        case .detected:
            section(app.isListening ? "Detected this call" : "From your last call") {
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

    private func upcomingRow(_ event: CalendarEvent) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                if let start = event.start {
                    Text(start.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                    Text(Calendar.current.isDateInToday(start) ? "Today" : "Tomorrow")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 62, alignment: .leading)
            Text(event.title).font(.callout).lineLimit(1)
            Spacer()
            if let service = event.conferenceService {
                Text(service)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
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
        // Greedy on both axes: centers itself in the constant-height content
        // region (below the call banner when one is showing).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Granola-style quick rows between content and the mode footer.
    private var menuRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuRow("Open OpenAvatar", icon: "macwindow") { openSettingsAndFocus() }
            menuRow("Call notes & transcript", icon: "note.text") {
#if canImport(AppKit)
                WindowManager.shared.showCallWindow()
#endif
            }
            HStack(spacing: 8) {
                Text("v\(UpdateManager.shared.currentVersion)")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Check for updates") { UpdateManager.shared.checkForUpdates() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
    }

    private func menuRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title).font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
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

/// The popover's content region is ONE constant height, for both tabs, in every
/// state — so the menu-bar window never has a reason to resize after it first
/// opens. Every popover layout bug so far (footer overlapping content, gaps
/// under the menu-bar icon on tab switch, blank space under short content) came
/// from dynamic sizing meeting MenuBarExtra's unreliable mid-open resizing.
/// A height estimate that merely *predicted* scrolling regressed twice; a
/// constant cannot be wrong.
enum PopoverLayout {
    static let contentHeight: CGFloat = 440
}

/// The ordered sections the content region renders, in presentation order.
enum PopoverSection: String, Equatable {
    case callSuggestion, error, upcoming, suggestions, approvals, detected, executed, empty
}

/// Pure view-model for the popover content: which sections show and whether
/// the empty state applies. The view renders straight from this, so
/// `PopoverContentTests` snapshots exactly what the user sees. Upcoming
/// meetings are informational — they show alongside the empty state rather
/// than suppressing it. (Non-empty content always lives in a ScrollView
/// inside the constant-height region, so "does it scroll" is no longer a
/// decision anything can get wrong.)
struct PopoverContent: Equatable {
    let sections: [PopoverSection]
    let isEmpty: Bool

    init(hasCallSuggestion: Bool, hasError: Bool, upcoming: Int,
         suggestions: Int, approvals: Int, detected: Int, executed: Int) {
        let empty = !hasError && suggestions == 0 && approvals == 0
            && detected == 0 && executed == 0
        var s: [PopoverSection] = []
        if hasCallSuggestion { s.append(.callSuggestion) }
        if hasError { s.append(.error) }
        if upcoming > 0 { s.append(.upcoming) }
        if suggestions > 0 { s.append(.suggestions) }
        if approvals > 0 { s.append(.approvals) }
        if detected > 0 { s.append(.detected) }
        if executed > 0 { s.append(.executed) }
        if empty { s.append(.empty) }
        self.sections = s
        self.isEmpty = empty
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
            Button {
                app.markDone(decision)
            } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.green)
                .help("Done — I already did this myself")
            // .menuStyle(.button) + borderless: the borderlessButton style with a
            // hidden indicator stopped opening the reason dropdown at all.
            Menu {
                ForEach(DismissReason.allCases, id: \.self) { reason in
                    Button(reasonLabel(reason)) { app.dismiss(decision, reason: reason) }
                }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            .help("Dismiss with a reason")
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
