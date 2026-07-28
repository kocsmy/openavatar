import SwiftUI

/// Renders the consolidator's Markdown meeting notes — topic headings with
/// detail bullets, Granola-style.
struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownNote.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 6)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text))
                    }
                    .font(.callout)
                case .text(let text):
                    Text(inline(text)).font(.callout)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown (bold, italics, code) within a block; plain on failure.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
