import SwiftUI

/// The per-call window (Granola-style): pops up in the background when a call
/// starts. "My notes" is the user's own scratchpad, autosaved onto the call
/// record and included in exports next to the AI-written meeting notes;
/// "Transcript" is the live feed.
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
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()

            Picker("", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            switch pane {
            case .notes:
                notesEditor
            case .transcript:
                LiveTranscriptView()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { loadDraft() }
        .onChange(of: app.currentCallID) { _, _ in loadDraft() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: app.isListening ? "waveform" : "checkmark.circle")
                .font(.title3)
                .foregroundStyle(app.isListening ? Color.red : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.isListening ? "Transcribing this call" : "Call ended")
                    .font(.headline)
                Text(app.isListening
                     ? "\(settings.assistantName) is taking notes — write your own alongside."
                     : "Your notes are saved with the call and included in exports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.isListening {
                Button("Stop") { app.stopListening() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    private var notesEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if draft.isEmpty {
                Text("Write your own notes for this call — saved automatically.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: draft) { _, newValue in
            scheduleSave(newValue)
        }
    }

    private func loadDraft() {
        guard let callID = app.currentCallID, loadedForCall != callID else { return }
        loadedForCall = callID
        draft = (try? app.store.callUserNotes(callID)) ?? ""
    }

    /// Debounced autosave: waits for a pause in typing, then persists.
    private func scheduleSave(_ text: String) {
        guard let callID = app.currentCallID else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            try? app.store.updateCallUserNotes(callID, text: text)
        }
    }
}
