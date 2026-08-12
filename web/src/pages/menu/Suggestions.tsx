import { Button } from "@/components/ui/button";
import type { MenuSuggestion } from "@/lib/types/menu";
import { CircleX, Lightbulb } from "lucide-react";
import { BoundedRows, SectionLabel } from "./common";

/** Mirrors MenuBarView.suggestionRow — proactive suggestions, always Ask-first. */
export function SuggestionsSection({
  items,
  onPrepare,
  onDismiss,
}: {
  items: MenuSuggestion[];
  onPrepare: (id: string) => void;
  onDismiss: (id: string) => void;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <SectionLabel>Suggestions</SectionLabel>
      <BoundedRows count={items.length} rowHeight={72}>
        {items.map((s) => (
          <SuggestionRow key={s.id} suggestion={s} onPrepare={() => onPrepare(s.id)} onDismiss={() => onDismiss(s.id)} />
        ))}
      </BoundedRows>
    </div>
  );
}

function SuggestionRow({
  suggestion,
  onPrepare,
  onDismiss,
}: {
  suggestion: MenuSuggestion;
  onPrepare: () => void;
  onDismiss: () => void;
}) {
  return (
    <div className="flex items-start gap-2 rounded-lg bg-card p-2.5 shadow-sm">
      <Lightbulb className="mt-0.5 size-3.5 shrink-0 text-warning" />
      <div className="min-w-0 flex-1">
        <p className="text-[12.5px] leading-snug">{suggestion.title}</p>
        <p className="mt-0.5 line-clamp-2 text-[11px] text-muted-foreground/70">{suggestion.rationale}</p>
      </div>
      <Button size="sm" variant="secondary" onClick={onPrepare} className="shrink-0">
        Prepare
      </Button>
      <button
        onClick={onDismiss}
        className="shrink-0 rounded p-1 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
      >
        <CircleX className="size-3.5" />
      </button>
    </div>
  );
}
