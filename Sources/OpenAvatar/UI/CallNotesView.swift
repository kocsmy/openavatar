import SwiftUI

/// The per-call window (Granola-style): pops up in the background when a call
/// starts. "My notes" is the user's own scratchpad, autosaved onto the call
/// record and included in exports next to the AI-written meeting notes;
/// "Transcript" is the live feed.
///
/// Before a call, the same window shows an UPCOMING meeting instead (click one
/// in the popover or Home): its details plus a notes pad saved against the
/// event — those notes seed the call's notes the moment the call starts.
struct CallNotesWindowView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    enum Pane: String, CaseIterable {
        case notes = "My notes"
        case transcript = "Transcript"
    }
    @State private var pane: Pane = .notes
    @State private var draft = ""
    @State private var loadedForCall: UUID?
    @State private var loadedForEvent: String?
    @State private var saveTask: Task<Void, Never>?

    /// Event preview only holds while no call is running — a live call always
    /// wins the window (startListening clears the preview).
    private var previewEvent: CalendarEvent? {
        app.isListening ? nil : app.previewEvent
    }

    /// The finished call's record — once present (and no live call or event
    /// preview owns the window), the window becomes that meeting's page.
    @State private var endedCall: ContextStore.CallRecord?

    var body: some View {
        Group {
            if !app.isListening, previewEvent == nil, let record = endedCall {
                // The call just ended: this window IS the review now —
                // actions to handle, the summary, and the transcript.
                MeetingDetailView(call: record, showsBack: false, initialPane: .actions)
            } else {
                liveBody
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .tint(.brand)
        .onAppear { loadDraft(); refreshEndedCall() }
        .onChange(of: app.currentCallID) { _, _ in loadDraft(); refreshEndedCall() }
        .onChange(of: app.previewEvent) { _, _ in loadDraft() }
        .onChange(of: app.isListening) { _, _ in loadDraft(); refreshEndedCall() }
        .onChange(of: app.isConsolidating) { _, _ in refreshEndedCall() }
    }

    private var liveBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let event = previewEvent {
                    eventHeader(event)
                } else {
                    callHeader
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            if previewEvent == nil {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if previewEvent != nil || pane == .notes {
                notesEditor
            } else {
                LiveTranscriptView()
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
        }
    }

    private func refreshEndedCall() {
        guard !app.isListening, let callID = app.currentCallID else {
            endedCall = nil
            return
        }
        endedCall = (try? app.store.listCalls(limit: 200))?.first { $0.id == callID }
    }

    // MARK: Headers

    private var callHeader: some View {
        HStack(spacing: DS.s12) {
            DSIconPlate(systemName: app.isListening ? "waveform" : "checkmark",
                        tint: app.isListening ? .red : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.isListening ? "Transcribing this call" : "Call ended")
                    .font(.headline)
                Text(app.isListening
                     ? "\(settings.assistantName) is taking notes — write your own alongside."
                     : "Your notes are saved with the call and included in exports.")
                    .font(.dsMeta).foregroundStyle(.secondary)
            }
            Spacer()
            if app.isListening {
                Button("Stop") { app.stopListening() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    private func eventHeader(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            DSIconPlate(systemName: "calendar", tint: .brand)
            VStack(alignment: .leading, spacing: DS.s4) {
                HStack(spacing: DS.s6) {
                    Text(event.title).font(.headline)
                    if let service = event.conferenceService {
                        DSChip(text: service)
                    }
                }
                DSMetaLine(parts: eventMeta(event))
                Text(settings.autoStartOnCall
                     ? "Notes written here carry into the call — transcription starts by itself when you join."
                     : "Notes written here carry into the call once you start listening.")
                    .font(.dsMeta).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func eventMeta(_ event: CalendarEvent) -> [String] {
        var parts: [String] = []
        if let start = event.start {
            parts.append(eventTimeLabel(start, event.end))
        }
        if let who = event.participantSummary(excludingSelfEmail: settings.calendarSelfEmail) {
            parts.append(who)
        }
        return parts
    }

    private func eventTimeLabel(_ start: Date, _ end: Date?) -> String {
        var label = start.formatted(date: .abbreviated, time: .shortened)
        if let end {
            label += " – " + end.formatted(date: .omitted, time: .shortened)
        }
        return label
    }

    // MARK: Notes

    private var notesEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, DS.s16)
                .padding(.vertical, DS.s8)
            if draft.isEmpty {
                // Mirror the TextEditor's text origin exactly (its padding plus
                // NSTextView's 5pt internal container inset) so the caret
                // blinks at the placeholder's first character, not beside it.
                Text(previewEvent == nil
                     ? "Write your own notes for this call — saved automatically."
                     : "Write your notes for this meeting ahead of time — saved automatically.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, DS.s16 + 5)
                    .padding(.vertical, DS.s8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: draft) { _, newValue in
            scheduleSave(newValue)
        }
    }

    private func loadDraft() {
        if previewEvent == nil {
            guard let callID = app.currentCallID, loadedForCall != callID else { return }
            loadedForCall = callID
            loadedForEvent = nil
            draft = (try? app.store.callUserNotes(callID)) ?? ""
        } else if let event = previewEvent {
            guard loadedForEvent != event.id else { return }
            loadedForEvent = event.id
            loadedForCall = nil
            draft = (try? app.store.eventNotes(eventID: event.id)) ?? ""
        }
    }

    /// Debounced autosave: waits for a pause in typing, then persists to the
    /// live call or, pre-call, to the upcoming event.
    private func scheduleSave(_ text: String) {
        let target: (callID: UUID?, event: CalendarEvent?)
        if let event = previewEvent {
            target = (nil, event)
        } else if let callID = app.currentCallID {
            target = (callID, nil)
        } else {
            return
        }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            if let callID = target.callID {
                try? app.store.updateCallUserNotes(callID, text: text)
            } else if let event = target.event {
                try? app.store.updateEventNotes(eventID: event.id, title: event.title,
                                                start: event.start, notes: text)
            }
        }
    }
}
