import SwiftUI
import UniformTypeIdentifiers

// MARK: - Live transcript (menu-bar popover tab)

/// Live, speaker-labeled transcript of the current call. Speakers use the
/// v1 two-channel model: your mic = "You", call audio = "Others".
struct LiveTranscriptView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .foregroundStyle(segment.source == .mic ? Color.accentColor : Color.secondary)
                .frame(width: 44, alignment: .leading)
            Text(segment.text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum TranscriptFormatter {
    /// Call-relative mm:ss.
    static func clock(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
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
                                        .foregroundStyle(segment.source == .mic ? Color.accentColor : Color.secondary)
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
