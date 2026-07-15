import SwiftUI

enum FollowUpFormatter {
    /// Friendly due-time string: "Today at 3:00 PM", "Tomorrow at 9:00 AM",
    /// "Overdue · Jul 14, 9:00 AM", or a full date further out.
    static func due(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if date < Date() {
            return "Overdue · " + date.formatted(date: .abbreviated, time: .shortened)
        }
        if cal.isDateInToday(date) { return "Today at \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(time)" }
        if let days = cal.dateComponents([.day], from: Date(), to: date).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Settings tab: manage confirmed follow-ups (upcoming + done).
struct FollowUpsSettingsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    @State private var scheduled: [FollowUp] = []
    @State private var done: [FollowUp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Follow-ups").font(.headline)
            Text("Things you said you'd revisit. When a call mentions a future item, confirm it in the post-call review — OpenAvatar then reminds you at its due time, even if the app was quit.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Capture follow-ups from calls", isOn: $settings.followUpsEnabled)
                .padding(.vertical, 2)

            if scheduled.isEmpty && done.isEmpty {
                ContentUnavailableView("No follow-ups yet", systemImage: "bell.slash",
                    description: Text("Confirm a follow-up in the post-call review and it'll appear here."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !scheduled.isEmpty {
                            Text("UPCOMING").font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary).kerning(0.4)
                            ForEach(scheduled) { row($0, isDone: false) }
                        }
                        if !done.isEmpty {
                            Text("DONE").font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary).kerning(0.4)
                                .padding(.top, 6)
                            ForEach(done) { row($0, isDone: true) }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Refresh") { load() }.controlSize(.small)
            }
        }
        .padding()
        .onAppear { load() }
    }

    private func row(_ followUp: FollowUp, isDone: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill"
                  : (followUp.isOverdue ? "exclamationmark.circle.fill" : "clock"))
                .foregroundStyle(isDone ? Color.green : (followUp.isOverdue ? Color.orange : Color.brand))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(followUp.title).font(.callout).strikethrough(isDone)
                Text(FollowUpFormatter.due(followUp.dueAt))
                    .font(.caption2)
                    .foregroundStyle(followUp.isOverdue && !isDone ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 8)
            if !isDone {
                Button("Done") { app.markFollowUpDone(followUp); load() }
                    .controlSize(.small)
                Menu("Snooze") {
                    Button("Tomorrow") { app.snoozeFollowUp(followUp, byDays: 1); load() }
                    Button("In 3 days") { app.snoozeFollowUp(followUp, byDays: 3); load() }
                    Button("Next week") { app.snoozeFollowUp(followUp, byDays: 7); load() }
                }
                .menuStyle(.button).controlSize(.small).fixedSize()
            }
            Button {
                app.deleteFollowUp(followUp); load()
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() {
        scheduled = app.scheduledFollowUps()
        done = app.completedFollowUps()
    }
}
