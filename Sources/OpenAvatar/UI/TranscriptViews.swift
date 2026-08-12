import SwiftUI
import UniformTypeIdentifiers

// MARK: - Live transcript (menu-bar popover tab)

/// Live, speaker-labeled transcript of the current call. Speakers use the
/// v1 two-channel model: your mic = "You", call audio = "Others".
struct LiveTranscriptView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpeakerRosterView()
            if app.liveSegments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: app.isListening ? "waveform" : "text.bubble")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text(app.isListening
                         ? "Listening — the transcript appears here as people speak…"
                         : "Start listening to see the live transcript. Past calls live under Meetings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(app.liveSegments) { segment in
                                TranscriptRow(segment: segment)
                                    .id(segment.id)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)   // fill the popover's constant-height region
                    .onChange(of: app.liveSegments.count) { _, _ in
                        if let last = app.liveSegments.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let last = app.liveSegments.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                HStack {
                    Button {
                        copyToClipboard(TranscriptFormatter.plainText(app.liveSegments))
                    } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                    Spacer()
                    Text("\(app.liveSegments.count) segments — saved automatically")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
#if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
    }
}

struct TranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(TranscriptFormatter.clock(segment.t0))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(segment.speakerLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TranscriptFormatter.color(for: segment))
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
            Text(segment.text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Editable speaker roster (live call)

/// Shows the distinct voices heard this call with inline renaming, plus the
/// calendar attendees as one-tap name suggestions. A name assigned here sticks
/// to the voice fingerprint — it relabels the whole transcript and carries to
/// future calls.
struct SpeakerRosterView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let speakers = app.callSpeakers
        if !speakers.isEmpty || app.currentEvent != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let event = app.currentEvent {
                    Label(event.title, systemImage: "calendar")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(speakers) { speaker in
                    SpeakerRosterRow(speaker: speaker)
                }
                if speakers.isEmpty, !app.callAttendees.isEmpty {
                    Text("Attendees: " + app.callAttendees.map(\.name).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        }
    }
}

struct SpeakerRosterRow: View {
    @EnvironmentObject var app: AppState
    let speaker: AppState.CallSpeaker
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(TranscriptFormatter.color(forSpeakerID: speaker.id, label: speaker.label))
                .frame(width: 8, height: 8)
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                    .onSubmit(commit)
                Button("Save", action: commit).controlSize(.small)
                Button("Cancel") { editing = false }.controlSize(.small)
            } else {
                Text(speaker.label).font(.caption.weight(.medium))
                Text("(\(speaker.segmentCount))").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if !app.callAttendees.isEmpty {
                    Menu {
                        ForEach(app.callAttendees) { attendee in
                            Button(attendee.name) { app.renameSpeaker(id: speaker.id, to: attendee.name) }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Assign a calendar attendee's name")
                }
                Button {
                    draft = speaker.label.hasPrefix("Speaker ") ? "" : speaker.label
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this voice")
            }
        }
    }

    private func commit() {
        app.renameSpeaker(id: speaker.id, to: draft)
        editing = false
    }
}

enum TranscriptFormatter {
    /// Call-relative mm:ss.
    static func clock(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    static let speakerPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]

    /// Stable, distinct color per speaker. "You" uses the accent color.
    static func color(for segment: TranscriptSegment) -> Color {
        if segment.source == .mic { return .accentColor }
        if let sid = segment.speakerID {
            return color(forSpeakerID: sid, label: segment.speaker)
        }
        // Fall back to the trailing number of a "Speaker N" label.
        if let speaker = segment.speaker, let n = Int(speaker.split(separator: " ").last ?? "") {
            return speakerPalette[(n - 1) % speakerPalette.count]
        }
        return .secondary
    }

    /// Deterministic color for a voice fingerprint id (stable across renames and
    /// app launches — unlike Swift's per-run String.hashValue).
    static func color(forSpeakerID id: String, label: String? = nil) -> Color {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return speakerPalette[Int(hash % UInt64(speakerPalette.count))]
    }

    static func plainText(_ segments: [TranscriptSegment], callStart: Date? = nil) -> String {
        segments.map { segment in
            let stamp: String
            if let callStart {
                let absolute = callStart.addingTimeInterval(segment.t0)
                stamp = absolute.formatted(date: .omitted, time: .standard)
            } else {
                stamp = clock(segment.t0)
            }
            return "[\(stamp)] \(segment.speakerLabel): \(segment.text)"
        }.joined(separator: "\n")
    }

    static func markdown(call: ContextStore.CallRecord, segments: [TranscriptSegment]) -> String {
        var lines = ["# \(call.displayTitle) — \(call.startedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let app = call.app { lines.append("App: \(app)") }
        if let summary = call.summary, !summary.isEmpty { lines.append("Summary: \(summary)") }
        if let notes = call.notes, !notes.isEmpty {
            lines.append("")
            lines.append(notes)
        }
        if let mine = call.userNotes, !mine.isEmpty {
            lines.append("")
            lines.append("## My notes")
            lines.append(mine)
        }
        lines.append("")
        lines.append(plainText(segments, callStart: call.startedAt))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Meetings (Settings "Library" tab)

/// Granola-style meetings library: a clean list of past calls; clicking one
/// switches the whole pane to that meeting's page (Summary / Actions /
/// Transcript) with a back button.
struct MeetingsTab: View {
    @EnvironmentObject var app: AppState
    @State private var calls: [ContextStore.CallRecord] = []
    @State private var selectedCallID: UUID?
    @State private var pendingDelete: ContextStore.CallRecord?

    var body: some View {
        Group {
            if let call = calls.first(where: { $0.id == selectedCallID }) {
                MeetingDetailView(call: call) {
                    selectedCallID = nil
                    load()
                }
            } else {
                meetingList
            }
        }
        .onAppear { load() }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayTitle ?? "meeting")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete meeting", role: .destructive) {
                if let call = pendingDelete {
                    app.deleteMeeting(call.id)
                    if selectedCallID == call.id { selectedCallID = nil }
                    load()
                }
                pendingDelete = nil
            }
        } message: {
            Text("The transcript, notes, and detected actions are removed. This can't be undone.")
        }
    }

    private func load() {
        calls = (try? app.store.listCalls()) ?? []
    }

    // MARK: List

    private var meetingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s24) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Meetings").font(.dsScreenTitle)
                    Spacer()
                    Button {
                        load()
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }

                if calls.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "text.quote",
                                           description: Text("Meetings appear here after your first call."))
                } else {
                    VStack(alignment: .leading, spacing: DS.s20) {
                        ForEach(days, id: \.day) { group in
                            daySection(group.day, calls: group.calls)
                        }
                    }
                }
            }
            .padding(DS.s24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var days: [(day: Date, calls: [ContextStore.CallRecord])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: calls) { cal.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    private func daySection(_ day: Date, calls: [ContextStore.CallRecord]) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSSectionLabel(text: dayLabel(day))
            ForEach(calls) { call in
                meetingRow(call)
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func meetingRow(_ call: ContextStore.CallRecord) -> some View {
        DSRow {
            selectedCallID = call.id
        } content: {
            HStack(alignment: .center, spacing: DS.s12) {
                VStack(alignment: .leading, spacing: DS.s4) {
                    HStack(spacing: DS.s6) {
                        Text(call.displayTitle).font(.dsRowTitle).lineLimit(1)
                        if let app = call.app, !app.isEmpty {
                            DSChip(text: app)
                        }
                    }
                    DSMetaLine(parts: rowMeta(call))
                }
                Spacer(minLength: DS.s8)
                Image(systemName: "chevron.right")
                    .font(.dsMeta)
                    .foregroundStyle(.quaternary)
            }
            .padding(DS.s12)
        }
        .contextMenu {
            Button("Delete meeting…", role: .destructive) { pendingDelete = call }
        }
    }

    private func rowMeta(_ call: ContextStore.CallRecord) -> [String] {
        var parts = [call.startedAt.formatted(date: .omitted, time: .shortened)]
        if let ended = call.endedAt {
            parts.append(MeetingFormat.duration(call.startedAt, ended))
        }
        if let summary = call.summary, !summary.isEmpty {
            parts.append(summary)
        }
        return parts
    }
}

enum MeetingFormat {
    static func duration(_ start: Date, _ end: Date) -> String {
        let minutes = max(1, Int(end.timeIntervalSince(start)) / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The call digest is action summaries joined with "; " — as prose it's a
    /// wall of text. Split it back into scannable bullets.
    static func digestBullets(_ digest: String) -> [String] {
        digest.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Meeting page (full-pane detail, Granola-style)

struct MeetingDetailView: View {
    @EnvironmentObject var app: AppState
    let call: ContextStore.CallRecord
    /// Hidden when the page is the whole window (post-call), shown inside the
    /// Meetings library.
    var showsBack: Bool = true
    var onBack: () -> Void = {}

    enum Pane: String, CaseIterable {
        case summary = "Summary"
        case actions = "Actions"
        case transcript = "Transcript"
    }
    @State private var pane: Pane

    init(call: ContextStore.CallRecord, showsBack: Bool = true,
         initialPane: Pane = .summary, onBack: @escaping () -> Void = {}) {
        self.call = call
        self.showsBack = showsBack
        self.onBack = onBack
        _pane = State(initialValue: initialPane)
    }
    @State private var segments: [TranscriptSegment] = []
    @State private var callSpeakers: [SpeakerProfile] = []
    @State private var allProfiles: [SpeakerProfile] = []
    @State private var decisions: [Decision] = []
    @State private var followUps: [FollowUp] = []
    @State private var message: String?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.s24)
                .padding(.top, DS.s16)
                .padding(.bottom, DS.s12)

            Picker("", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, DS.s24)
            .padding(.bottom, DS.s12)

            Divider()

            switch pane {
            case .summary: summaryPane
            case .actions: actionsPane
            case .transcript: transcriptPane
            }
        }
        .onAppear { reload() }
        // Right after a call, detection and note-writing land asynchronously —
        // keep the page current as they do.
        .onChange(of: app.isConsolidating) { _, _ in reload() }
        .onChange(of: app.detectedDecisions.count) { _, _ in reload() }
        .confirmationDialog("Delete “\(call.displayTitle)”?",
                            isPresented: $confirmingDelete) {
            Button("Delete meeting", role: .destructive) {
                app.deleteMeeting(call.id)
                onBack()
            }
        } message: {
            Text("The transcript, notes, and detected actions are removed. This can't be undone.")
        }
    }

    private func reload() {
        segments = (try? app.store.segments(callID: call.id)) ?? []
        callSpeakers = (try? app.store.speakerProfiles(callID: call.id)) ?? []
        allProfiles = (try? app.store.allSpeakerProfiles()) ?? []
        decisions = (try? app.store.decisions(callID: call.id)) ?? []
        followUps = (try? app.store.followUps(callID: call.id)) ?? []
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            HStack {
                if showsBack {
                    DSRow(style: .ghost) {
                        onBack()
                    } content: {
                        Label("Meetings", systemImage: "chevron.left")
                            .font(.dsBody)
                            .padding(.horizontal, DS.s8)
                            .padding(.vertical, DS.s4)
                    }
                }
                Spacer()
                if let message {
                    Text(message).font(.dsMeta).foregroundStyle(.secondary)
                }
                Menu {
                    Button("Export as Markdown…") { exportMarkdown() }
                        .disabled(segments.isEmpty)
                    Button("Copy transcript") { copyTranscript() }
                        .disabled(segments.isEmpty)
                    Divider()
                    Button("Tidy up stray voices") {
                        let folded = app.sweepStrayVoices()
                        message = folded > 0
                            ? "Folded \(folded) stray voice\(folded == 1 ? "" : "s") away."
                            : "No stray voices close enough to fold."
                        reload()
                    }
                    .disabled(app.isListening)
                    Divider()
                    Button("Delete meeting…", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(call.displayTitle)
                .font(.dsPageTitle)
                .lineLimit(2)
                .padding(.top, DS.s4)

            DSMetaLine(parts: headerMeta)

            if !callSpeakers.isEmpty {
                speakerStrip
                    .padding(.top, DS.s4)
            }
        }
    }

    private var headerMeta: [String] {
        var parts = [call.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let ended = call.endedAt {
            parts.append(MeetingFormat.duration(call.startedAt, ended))
        }
        if let hostApp = call.app, !hostApp.isEmpty {
            parts.append(hostApp)
        }
        if !callSpeakers.isEmpty {
            parts.append("\(callSpeakers.count) speaker\(callSpeakers.count == 1 ? "" : "s")")
        }
        return parts
    }

    /// The people heard on this call as chips — click one to rename, merge, or
    /// split its voice. Replaces the old cramped disclosure list.
    private var speakerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.s6) {
                ForEach(callSpeakers) { profile in
                    SpeakerChip(
                        profile: profile,
                        others: allProfiles.filter { $0.id != profile.id },
                        onRename: { newName in
                            app.renameSpeaker(id: profile.id.uuidString, to: newName)
                            reload()
                        },
                        onMerge: { targetID in
                            app.mergeSpeaker(sourceID: profile.id.uuidString,
                                             into: targetID.uuidString)
                            reload()
                        },
                        onDetach: {
                            _ = app.detachSpeaker(callID: call.id, from: profile.id.uuidString)
                            reload()
                        })
                }
            }
        }
    }

    // MARK: Summary

    /// The freshest notes available: for the just-ended call, consolidation
    /// publishes them before the list's record snapshot refreshes.
    private var resolvedNotes: String? {
        if call.id == app.currentCallID, let live = app.reviewCallNotes, !live.isEmpty {
            return live
        }
        return call.notes
    }

    private var summaryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s16) {
                if let notes = resolvedNotes, !notes.isEmpty {
                    MeetingNotesView(markdown: notes)
                } else if app.isConsolidating {
                    HStack(spacing: DS.s8) {
                        ProgressView().controlSize(.small)
                        Text("Writing meeting notes…").font(.dsBody).foregroundStyle(.secondary)
                    }
                } else if let summary = call.summary, !summary.isEmpty {
                    // Older calls without structured notes: the digest as
                    // scannable bullets, never a wall of text.
                    VStack(alignment: .leading, spacing: DS.s6) {
                        DSSectionLabel(text: "What came out of it")
                        ForEach(Array(MeetingFormat.digestBullets(summary).enumerated()),
                                id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: DS.s8) {
                                Text("•").font(.dsReading).foregroundStyle(Color.brand)
                                Text(item).font(.dsReading).lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No notes for this meeting", systemImage: "note.text",
                                           description: Text("Notes are written when a call ends with a transcript."))
                }

                if let mine = call.userNotes, !mine.isEmpty {
                    VStack(alignment: .leading, spacing: DS.s6) {
                        DSSectionLabel(text: "My notes")
                        Text(mine)
                            .font(.dsReading)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(DS.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.surface,
                                in: RoundedRectangle(cornerRadius: DS.rMedium, style: .continuous))
                }
            }
            .padding(DS.s24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    private var actionsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s20) {
                if decisions.isEmpty && followUps.isEmpty {
                    ContentUnavailableView("No actions from this meeting", systemImage: "checklist",
                                           description: Text("Action items and follow-ups detected on a call show up here."))
                }
                if !decisions.isEmpty {
                    VStack(alignment: .leading, spacing: DS.s8) {
                        DSSectionLabel(text: "Action items")
                        ForEach(decisions) { decision in
                            decisionRow(decision)
                        }
                    }
                }
                if !followUps.isEmpty {
                    VStack(alignment: .leading, spacing: DS.s8) {
                        DSSectionLabel(text: "Follow-ups")
                        ForEach(followUps) { followUp in
                            followUpRow(followUp)
                        }
                    }
                }
            }
            .padding(DS.s24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A detected action item. Pending ones carry the review actions right
    /// here (Prepare / Done myself / Dismiss) — the meeting page IS the
    /// review now. Handled ones show their outcome.
    private func decisionRow(_ decision: Decision) -> some View {
        actionRow(icon: "checklist",
                  title: decision.summary,
                  detail: decision.quote) {
            if decision.status == .detected {
                Button("Prepare") { app.prepare(decision); reload() }
                    .controlSize(.small)
                Button {
                    app.markDone(decision); reload()
                } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.green)
                    .help("Done — I already did this myself")
                Menu {
                    ForEach(DismissReason.allCases, id: \.self) { reason in
                        Button(reason.displayName) { app.dismiss(decision, reason: reason); reload() }
                    }
                } label: { Image(systemName: "xmark.circle") }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Dismiss with a reason")
            } else {
                let badge = decisionBadge(decision.status)
                DSChip(text: badge.0, tint: badge.1)
            }
        }
    }

    /// A time-referenced follow-up. Suggested ones confirm (→ reminder) or
    /// dismiss inline; the rest show their state.
    private func followUpRow(_ followUp: FollowUp) -> some View {
        actionRow(icon: "bell",
                  title: followUp.title,
                  detail: "Due " + followUp.dueAt.formatted(date: .abbreviated, time: .shortened)) {
            if followUp.status == .suggested {
                Button("Remind me") { app.confirmFollowUp(followUp); reload() }
                    .controlSize(.small)
                Button {
                    app.dismissFollowUp(followUp); reload()
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            } else {
                let badge = followUpBadge(followUp.status)
                DSChip(text: badge.0, tint: badge.1)
            }
        }
    }

    private func actionRow<Trailing: View>(
        icon: String, title: String, detail: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: icon)
                .foregroundStyle(Color.brand)
                .frame(width: 18)
                .padding(.top, DS.s2)
            VStack(alignment: .leading, spacing: DS.s2) {
                Text(title).font(.dsBody)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.dsMeta).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            trailing()
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.rMedium, style: .continuous))
    }

    private func decisionBadge(_ status: DecisionStatus) -> (String, Color) {
        switch status {
        case .detected: return ("Needs review", .orange)
        case .approved, .edited: return ("Approved", .blue)
        case .executed: return ("Executed", .green)
        case .done: return ("Done by you", .blue)
        case .dismissed: return ("Dismissed", .secondary)
        case .reverted: return ("Reverted", .secondary)
        }
    }

    private func followUpBadge(_ status: FollowUpStatus) -> (String, Color) {
        switch status {
        case .suggested: return ("Suggested", .orange)
        case .scheduled: return ("Scheduled", .blue)
        case .done: return ("Done", .green)
        case .dismissed: return ("Dismissed", .secondary)
        }
    }

    // MARK: Transcript

    private var transcriptPane: some View {
        Group {
            if segments.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.quote",
                                       description: Text("No transcript segments were saved for this call."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.s6) {
                        ForEach(segments) { segment in
                            HStack(alignment: .top, spacing: DS.s6) {
                                Text(wallClock(segment.t0))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(segment.speakerLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(TranscriptFormatter.color(for: segment))
                                    .frame(width: 76, alignment: .leading)
                                Text(segment.text)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(DS.s24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func wallClock(_ t: TimeInterval) -> String {
        call.startedAt.addingTimeInterval(t).formatted(date: .omitted, time: .standard)
    }

    // MARK: Export

    private func copyTranscript() {
#if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TranscriptFormatter.plainText(segments, callStart: call.startedAt),
            forType: .string)
        message = "Copied"
#endif
    }

    private func exportMarkdown() {
#if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "transcript-\(call.startedAt.formatted(.iso8601.year().month().day())).md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let markdown = TranscriptFormatter.markdown(call: call, segments: segments)
                try Data(markdown.utf8).write(to: url)
                message = "Exported to \(url.lastPathComponent)"
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
#endif
    }
}

// MARK: - Speaker chip (click to rename / merge / split)

struct SpeakerChip: View {
    let profile: SpeakerProfile
    let others: [SpeakerProfile]
    var onRename: (String?) -> Void
    var onMerge: (UUID) -> Void
    var onDetach: () -> Void

    @State private var editing = false
    @State private var hovering = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = profile.name ?? ""
            editing = true
        } label: {
            HStack(spacing: DS.s4 + 1) {
                Circle()
                    .fill(TranscriptFormatter.color(forSpeakerID: profile.id.uuidString))
                    .frame(width: 8, height: 8)
                Text(profile.displayLabel).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, DS.s8 + 1)
            .padding(.vertical, DS.s4)
            .background(hovering ? DS.surfaceHover : DS.surface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Rename, merge, or split this voice")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.s12) {
                Text("Who is this?").font(.dsRowTitle)
                HStack(spacing: DS.s6) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .onSubmit(commit)
                    Button("Save", action: commit)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: DS.s8) {
                    if profile.isNamed {
                        Button("Clear name") { onRename(nil); editing = false }
                            .controlSize(.small)
                    }
                    if !others.isEmpty {
                        Menu("Merge into…") {
                            ForEach(others) { target in
                                Button(target.displayLabel) { onMerge(target.id); editing = false }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Combine this voice into another (this one disappears)")
                    }
                    Button("Not them") { onDetach(); editing = false }
                        .controlSize(.small)
                        .help("Wrong person? Move this call's voice to a new, separate speaker")
                }
                Text("\(profile.sampleCount) utterances · a name sticks to this voice across calls")
                    .font(.dsMeta).foregroundStyle(.tertiary)
            }
            .padding(DS.s16)
        }
    }

    private func commit() {
        onRename(draft)
        editing = false
    }
}
