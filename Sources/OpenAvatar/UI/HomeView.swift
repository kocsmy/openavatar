import SwiftUI

/// Home: the week ahead ("Coming up", Granola-style) plus live capture state.
/// Meetings come from the connected Google Calendar; joining a call still
/// works without any calendar — mic-ownership detection starts the notes.
struct HomeTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s24) {
                Text("Coming up")
                    .font(.dsScreenTitle)

                statusCard

                if !settings.calendarEnabled || app.upcomingEvents.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: DS.s24) {
                        ForEach(days, id: \.day) { group in
                            daySection(group.day, events: group.events)
                        }
                    }
                }
            }
            .padding(DS.s24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            app.refreshUpcomingEvents()
        }
    }

    // MARK: Capture status

    @ViewBuilder private var statusCard: some View {
        HStack(spacing: DS.s12) {
            if app.isListening {
                DSIconPlate(systemName: "waveform", tint: .green)
                Text("Transcribing now — notes and action items are being taken.")
                    .font(.dsBody)
                Spacer()
                Button("Stop") { app.stopListening() }.controlSize(.small)
            } else if settings.autoStartOnCall {
                DSIconPlate(systemName: "bolt.fill", tint: .brand)
                Text("When you join a call, transcription starts by itself — no clicks needed.")
                    .font(.dsBody).foregroundStyle(.secondary)
                Spacer()
            } else {
                DSIconPlate(systemName: "hand.raised", tint: .secondary)
                Text("Auto-start is off — start capture from the menu bar when a call begins (or turn it on in General).")
                    .font(.dsBody).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(DS.s12)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.rLarge, style: .continuous))
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
                description: Text("No meetings in the next 7 days on your selected calendar."))
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
        HStack(alignment: .top, spacing: DS.s16) {
            VStack(spacing: 0) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Calendar.current.isDateInToday(day) ? Color.brand : .primary)
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.dsMeta).foregroundStyle(.secondary)
            }
            .frame(width: 44)
            .padding(.top, DS.s6)

            VStack(alignment: .leading, spacing: DS.s8) {
                ForEach(events) { event in
                    eventRow(event)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The whole row opens the meeting's notes page — pre-write notes there;
    /// they carry into the call once it starts.
    private func eventRow(_ event: CalendarEvent) -> some View {
        DSRow {
            app.openEventNotes(event)
        } content: {
            HStack(alignment: .center, spacing: DS.s12) {
                VStack(alignment: .leading, spacing: DS.s4) {
                    HStack(spacing: DS.s6) {
                        Text(event.title).font(.dsRowTitle).lineLimit(1)
                        if isNow(event) {
                            DSChip(text: "Now", tint: .green)
                        }
                        if let service = event.conferenceService {
                            DSChip(text: service)
                        }
                    }
                    DSMetaLine(parts: metaParts(event))
                }
                Spacer(minLength: DS.s8)
                if isNow(event) && !app.isListening {
                    Button("Start notes") { app.startListening() }
                        .controlSize(.small)
                        .tint(.brand)
                }
                Image(systemName: "chevron.right")
                    .font(.dsMeta)
                    .foregroundStyle(.quaternary)
            }
            .padding(DS.s12)
        }
        .help("Open this meeting's notes — write yours before the call starts")
    }

    private func metaParts(_ event: CalendarEvent) -> [String] {
        var parts: [String] = []
        if let start = event.start {
            parts.append(timeRange(start, event.end))
        }
        if let who = event.participantSummary(excludingSelfEmail: settings.calendarSelfEmail) {
            parts.append(who)
        }
        return parts
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
