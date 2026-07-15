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
                Text(app.isListening
                     ? "Listening — the transcript appears here as people speak…"
                     : "Start listening to see the live transcript. Past calls live in Settings → Transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
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
                    .frame(maxHeight: 340)
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
        var lines = ["# Call transcript — \(call.startedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let app = call.app { lines.append("App: \(app)") }
        if let summary = call.summary, !summary.isEmpty { lines.append("Summary: \(summary)") }
        lines.append("")
        lines.append(plainText(segments, callStart: call.startedAt))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Named voices library (rename / merge any voice, past or present)

/// Lists every stored voice fingerprint with an editable name. Renaming here
/// relabels that voice everywhere; merging folds one voice into another to fix
/// a person who was split across several "Speaker N" entries.
struct SpeakerLibraryView: View {
    @EnvironmentObject var app: AppState
    /// Called after a rename/merge so the parent can reload any visible transcript.
    var onRename: () -> Void = {}

    @State private var profiles: [SpeakerProfile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Named voices").font(.headline)
                Spacer()
                Button("Refresh") { load() }.controlSize(.small)
            }
            Text("Name a voice once and it's recognized in every call — past transcripts are relabeled too. If one person shows up as several voices, use Merge to combine them.")
                .font(.caption).foregroundStyle(.secondary)

            if profiles.isEmpty {
                Text("No voices captured yet. They appear here after a call with per-voice diarization on.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                ForEach(profiles) { profile in
                    SpeakerLibraryRow(
                        profile: profile,
                        others: profiles.filter { $0.id != profile.id },
                        onCommit: { newName in
                            app.renameSpeaker(id: profile.id.uuidString, to: newName)
                            load(); onRename()
                        },
                        onMerge: { targetID in
                            app.mergeSpeaker(sourceID: profile.id.uuidString, into: targetID.uuidString)
                            load(); onRename()
                        })
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        profiles = (try? app.store.allSpeakerProfiles()) ?? []
    }
}

struct SpeakerLibraryRow: View {
    let profile: SpeakerProfile
    let others: [SpeakerProfile]
    var onCommit: (String?) -> Void
    var onMerge: (UUID) -> Void

    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(TranscriptFormatter.color(forSpeakerID: profile.id.uuidString))
                .frame(width: 9, height: 9)
            TextField("Speaker \(profile.ordinal)", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .onSubmit { onCommit(draft) }
            Button("Save") { onCommit(draft) }
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            if profile.isNamed {
                Button("Clear") { draft = ""; onCommit(nil) }
                    .controlSize(.small)
            }
            if !others.isEmpty {
                Menu("Merge into…") {
                    ForEach(others) { target in
                        Button(target.displayLabel) { onMerge(target.id) }
                    }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Combine this voice into another (this one disappears)")
            }
            Text("\(profile.sampleCount) utterances")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .onAppear { draft = profile.name ?? "" }
    }
}

// MARK: - Saved transcripts (Settings tab)

/// Browse every saved call: full transcript with speaker labels and
/// wall-clock timestamps, plus Markdown export.
struct TranscriptsSettingsTab: View {
    @EnvironmentObject var app: AppState
    @State private var calls: [ContextStore.CallRecord] = []
    @State private var selectedCallID: UUID?
    @State private var segments: [TranscriptSegment] = []
    @State private var message: String?

    private var selectedCall: ContextStore.CallRecord? {
        calls.first { $0.id == selectedCallID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved transcripts").font(.headline)
            Text("Every call is transcribed and stored locally with timestamps. Select a call to read or export it.")
                .font(.caption).foregroundStyle(.secondary)

            SpeakerLibraryView {
                // Reload the visible transcript so renames show immediately.
                if let id = selectedCallID { segments = (try? app.store.segments(callID: id)) ?? [] }
            }
            Divider()

            if calls.isEmpty {
                ContentUnavailableView("No calls yet", systemImage: "text.quote",
                                       description: Text("Transcripts appear here after your first listening session."))
            } else {
                List(calls, selection: $selectedCallID) { call in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout)
                            if let app = call.app {
                                Text(app).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let ended = call.endedAt {
                                Text(durationLabel(call.startedAt, ended))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let summary = call.summary, !summary.isEmpty {
                            Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(call.id)
                }
                .frame(height: 150)

                Divider()

                if segments.isEmpty {
                    Text(selectedCallID == nil ? "Select a call above."
                                               : "No transcript segments were saved for this call.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(segments) { segment in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(wallClock(segment.t0))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text(segment.speakerLabel)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(TranscriptFormatter.color(for: segment))
                                        .frame(width: 44, alignment: .leading)
                                    Text(segment.text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack {
                    Button {
                        if let id = selectedCallID { app.reviewPastCall(id) }
                    } label: { Label("Open call review", systemImage: "checklist") }
                        .disabled(selectedCallID == nil
                                  || app.isListening
                                  || !(selectedCallID.map { app.hasReviewableDecisions($0) } ?? false))
                        .help(app.isListening
                              ? "Available when you're not in a live call"
                              : "Re-open the action-item review for this call")
                    Button("Export as Markdown…") { exportMarkdown() }
                        .disabled(segments.isEmpty)
                    Button {
                        copyToClipboard()
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(segments.isEmpty)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Refresh") { load() }
                }
            }
        }
        .padding()
        .onAppear { load() }
        .onChange(of: selectedCallID) { _, callID in
            segments = callID.flatMap { try? app.store.segments(callID: $0) } ?? []
        }
    }

    private func load() {
        calls = (try? app.store.listCalls()) ?? []
        if selectedCallID == nil, let first = calls.first {
            selectedCallID = first.id
            segments = (try? app.store.segments(callID: first.id)) ?? []
        }
    }

    private func wallClock(_ t: TimeInterval) -> String {
        guard let call = selectedCall else { return TranscriptFormatter.clock(t) }
        return call.startedAt.addingTimeInterval(t)
            .formatted(date: .omitted, time: .standard)
    }

    private func durationLabel(_ start: Date, _ end: Date) -> String {
        let minutes = max(1, Int(end.timeIntervalSince(start)) / 60)
        return "\(minutes) min"
    }

    private func copyToClipboard() {
#if canImport(AppKit)
        guard let call = selectedCall else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TranscriptFormatter.plainText(segments, callStart: call.startedAt),
            forType: .string)
        message = "Copied"
#endif
    }

    private func exportMarkdown() {
#if canImport(AppKit)
        guard let call = selectedCall else { return }
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
