import SwiftUI

/// Home: the week ahead ("Coming up", Granola-style) plus live capture state.
/// Meetings come from the connected Google Calendar; joining a call still
/// works without any calendar — mic-ownership detection starts the notes.
struct HomeTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Coming up")
                    .font(.title2.weight(.semibold))

                statusCard

                if !settings.calendarEnabled || app.upcomingEvents.isEmpty {
                    emptyState
                } else {
                    ForEach(days, id: \.day) { group in
                        daySection(group.day, events: group.events)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            app.refreshUpcomingEvents()
        }
    }

    // MARK: Capture status

    @ViewBuilder private var statusCard: some View {
        HStack(spacing: 10) {
            Image(systemName: app.isListening ? "waveform.circle.fill"
                                              : (settings.autoStartOnCall ? "bolt.circle" : "hand.raised.circle"))
                .font(.title3)
                .foregroundStyle(app.isListening ? Color.green : Color.brand)
            if app.isListening {
                Text("Transcribing now — notes and action items are being taken.")
                    .font(.callout)
                Spacer()
                Button("Stop") { app.stopListening() }.controlSize(.small)
            } else if settings.autoStartOnCall {
                Text("When you join a call, transcription starts by itself — no clicks needed.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Auto-start is off — start capture from the menu bar when a call begins (or turn it on in General).")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var emptyState: some View {
        if !settings.calendarEnabled {
            ContentUnavailableView(
                "No calendar connected",
                systemImage: "calendar.badge.plus",
                description: Text("Connect Google Calendar under Integrations to see your upcoming meetings here. Call detection and transcription work without it."))
        } else {
            ContentUnavailableView(
                "Nothing scheduled",
                systemImage: "calendar",
                description: Text("No meetings in the next 7 days on your primary calendar."))
        }
    }

    // MARK: Days

    private var days: [(day: Date, events: [CalendarEvent])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: app.upcomingEvents.filter { $0.start != nil }) {
            cal.startOfDay(for: $0.start!)
        }
        return grouped.keys.sorted().map { day in
            (day, grouped[day]!.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) })
        }
    }

    private func daySection(_ day: Date, events: [CalendarEvent]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(day.formatted(.dateTime.day()))
                    .font(.title2.weight(.semibold))
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    eventRow(event)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    /// The whole card opens the meeting's notes page — pre-write notes there;
    /// they carry into the call once it starts.
    private func eventRow(_ event: CalendarEvent) -> some View {
        Button {
            app.openEventNotes(event)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.brand)
                    .frame(width: 3, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.title).font(.callout.weight(.medium))
                        if isNow(event) {
                            Text("Now")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.green.opacity(0.18), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 6) {
                        if let start = event.start {
                            Text(timeRange(start, event.end))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let service = event.conferenceService {
                            Text(service)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.brand.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.brand)
                        }
                        if let who = event.participantSummary(excludingSelfEmail: settings.calendarSelfEmail) {
                            Label(who, systemImage: "person.2")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                Spacer()
                if isNow(event) && !app.isListening {
                    Button("Start notes") { app.startListening() }
                        .controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open this meeting's notes — write yours before the call starts")
    }

    private func isNow(_ event: CalendarEvent) -> Bool {
        guard let start = event.start, let end = event.end else { return false }
        let now = Date()
        return start <= now && now <= end
    }

    private func timeRange(_ start: Date, _ end: Date?) -> String {
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        if let end { return "\(start.formatted(f)) – \(end.formatted(f))" }
        return start.formatted(f)
    }
}
