import Foundation

/// Minimal block-level Markdown model for LLM-written meeting notes.
/// SwiftUI's AttributedString only handles inline Markdown, so headings and
/// bullets are split out here and styled by the view; inline emphasis inside
/// each block is still rendered by AttributedString.
enum MarkdownNote {
    enum Block: Equatable {
        case heading(String)
        /// level 0 = top-level bullet, 1+ = nested detail bullet.
        case bullet(String, Int)
        case text(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        markdown.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            for marker in ["### ", "## ", "# "] where line.hasPrefix(marker) {
                return .heading(String(line.dropFirst(marker.count)))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                // Nesting from the leading indent (2 spaces or a tab per level).
                let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                    .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
                return .bullet(String(line.dropFirst(2)), min(2, indent / 2))
            }
            return .text(line)
        }
    }
}
