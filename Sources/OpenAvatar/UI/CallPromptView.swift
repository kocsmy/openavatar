import SwiftUI

/// The floating "call detected" prompt (Granola-style): a small panel under
/// the menu bar when an app takes the microphone and recording hasn't
/// started. One click starts the notes; ✕ dismisses it for this call.
struct CallPromptView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: DS.s12) {
            Button {
                app.dismissCallPrompt()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(DS.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Not a call — don't ask again until it ends")

            VStack(alignment: .leading, spacing: 1) {
                Text("Call detected")
                    .font(.dsRowTitle)
                Text(app.callPromptApp ?? "")
                    .font(.dsMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DS.s16)

            Button {
                app.acceptCallPrompt()
            } label: {
                Label("Take notes", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .tint(.brand)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.s12)
        .padding(.vertical, DS.s8 + 2)
        .frame(width: 330)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: DS.rLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.rLarge, style: .continuous)
            .strokeBorder(DS.hairline, lineWidth: 1))
    }
}
