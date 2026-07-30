import SwiftUI

/// Renders the consolidator's Markdown meeting notes — topic headings with
/// detail bullets and nested sub-bullets, Granola-style. Reading typography
/// is a step larger than UI chrome: these are documents, not controls.
struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            ForEach(Array(MarkdownNote.parse(markdown).enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .font(.dsReadingHeading)
                        .padding(.top, index == 0 ? 0 : DS.s12)
                case .bullet(let text, let level):
                    HStack(alignment: .top, spacing: DS.s8) {
                        Text(level == 0 ? "•" : "◦")
                            .font(.dsReading)
                            .foregroundStyle(level == 0 ? Color.brand : Color.secondary)
                        Text(inline(text))
                            .font(.dsReading)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(level) * 18)
                case .text(let text):
                    Text(inline(text))
                        .font(.dsReading)
                        .lineSpacing(3)
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
