import * as React from "react";
import { cn } from "@/lib/utils";

/*
 * Minimal Markdown — mirrors Core/MarkdownNote.swift's block parser (headings,
 * bullets, plain text) plus a small **bold** / *italic* / `code` inline pass,
 * and ordered lists, which answers enumerate far more often than notes do.
 *
 * No markdown dependency is in package.json and this app can't add one. Shared
 * by the meeting notes and the ask threads: an answer arrives as Markdown just
 * like the consolidator's notes do, and rendering one as prose and the other
 * as raw asterisks was only ever an oversight.
 */

type MdBlock =
  | { kind: "heading"; text: string }
  | { kind: "bullet"; text: string; level: number; marker: string | null }
  | { kind: "text"; text: string };

export function parseMarkdownBlocks(markdown: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  for (const raw of markdown.split("\n")) {
    const line = raw.trim();
    if (!line) continue;

    const heading = ["### ", "## ", "# "].find((marker) => line.startsWith(marker));
    if (heading) {
      blocks.push({ kind: "heading", text: line.slice(heading.length) });
      continue;
    }

    let indent = 0;
    for (const ch of raw) {
      if (ch === " ") indent += 1;
      else if (ch === "\t") indent += 2;
      else break;
    }
    const level = Math.min(2, Math.floor(indent / 2));

    if (line === "-" || line === "*") continue;
    if (line.startsWith("- ") || line.startsWith("* ")) {
      // A streaming answer arrives mid-line, so an empty bullet is a list item
      // whose text hasn't landed yet — drawing the dot alone flickers.
      const text = line.slice(2).trim();
      if (text) blocks.push({ kind: "bullet", text, level, marker: null });
      continue;
    }
    // "1." / "2)" — keep the author's own numbering rather than recomputing it,
    // so a list that starts at 3 still reads as 3.
    const ordered = line.match(/^(\d{1,2})[.)]\s+(.*)$/);
    if (ordered) {
      blocks.push({ kind: "bullet", text: ordered[2], level, marker: `${ordered[1]}.` });
      continue;
    }

    blocks.push({ kind: "text", text: line });
  }
  return blocks;
}

export function renderInline(text: string): React.ReactNode {
  const parts = text.split(/(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)/g).filter((p) => p.length > 0);
  return parts.map((part, i) => {
    if (part.startsWith("**") && part.endsWith("**")) return <strong key={i}>{part.slice(2, -2)}</strong>;
    if (part.startsWith("`") && part.endsWith("`")) {
      return (
        <code key={i} className="rounded bg-muted px-1 py-0.5 text-[12px]">
          {part.slice(1, -1)}
        </code>
      );
    }
    if (part.startsWith("*") && part.endsWith("*")) return <em key={i}>{part.slice(1, -1)}</em>;
    return <React.Fragment key={i}>{part}</React.Fragment>;
  });
}

export function Markdown({ markdown, className }: { markdown: string; className?: string }) {
  const blocks = React.useMemo(() => parseMarkdownBlocks(markdown), [markdown]);
  return (
    <div className={cn("flex flex-col gap-2", className)} data-selectable>
      {blocks.map((b, i) => {
        if (b.kind === "heading") {
          return (
            <p key={i} className={cn("text-[15px] font-semibold", i > 0 && "mt-2")}>
              {renderInline(b.text)}
            </p>
          );
        }
        if (b.kind === "bullet") {
          return (
            <div key={i} className="flex items-start gap-2" style={{ paddingLeft: b.level * 18 }}>
              <span
                className={cn(
                  "mt-0.5 shrink-0 text-sm",
                  b.marker ? "tabular-nums text-muted-foreground" : b.level === 0 ? "text-primary" : "text-muted-foreground",
                )}
              >
                {b.marker ?? (b.level === 0 ? "•" : "◦")}
              </span>
              <p className="flex-1 text-[13.5px] leading-relaxed">{renderInline(b.text)}</p>
            </div>
          );
        }
        return (
          <p key={i} className="text-[13.5px] leading-relaxed">
            {renderInline(b.text)}
          </p>
        );
      })}
    </div>
  );
}
