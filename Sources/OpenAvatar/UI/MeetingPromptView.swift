import SwiftUI

/// The floating pre-meeting prompt: appears a minute before a calendar event
/// starts, names the meeting and who's on it, and joins the call (Zoom, Meet,
/// wherever the event points) with notes already running — one click covers
/// both. ✕ dismisses it for this event.
struct MeetingPromptView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        if let event = app.meetingPrompt {
            HStack(spacing: DS.s12) {
                Button {
                    app.dismissMeetingPrompt()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(DS.surface, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Skip this meeting")

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.dsRowTitle)
                        .lineLimit(1)
                    Text(meta(event))
                        .font(.dsMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DS.s16)

                Button {
                    app.joinMeeting(event)
                } label: {
                    Label(event.meetingURL != nil ? "Join & take notes" : "Take notes",
                          systemImage: event.meetingURL != nil ? "video" : "waveform")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.s12)
            .padding(.vertical, DS.s8 + 2)
            .frame(width: 380)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.rLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rLarge, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 1))
        }
    }

    private func meta(_ event: CalendarEvent) -> String {
        var parts = [Self.startLabel(event.start, now: Date())]
        if let who = event.participantSummary(excludingSelfEmail: settings.calendarSelfEmail) {
            parts.append(who)
        }
        if let service = event.conferenceService {
            parts.append(service)
        }
        return parts.joined(separator: "  ·  ")
    }

    static func startLabel(_ start: Date?, now: Date) -> String {
        guard let start else { return "Starting soon" }
        let seconds = start.timeIntervalSince(now)
        if seconds > 45 {
            let minutes = max(1, Int((seconds / 60).rounded()))
            return "Starts in \(minutes) min"
        }
        if seconds > -90 { return "Starting now" }
        return "Started \(max(2, Int((-seconds / 60).rounded()))) min ago"
    }
}
