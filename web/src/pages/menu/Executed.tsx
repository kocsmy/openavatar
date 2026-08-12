import { Button } from "@/components/ui/button";
import { ExternalLink } from "@/components/shared";
import type { MenuExecutedAction } from "@/lib/types/menu";
import { CheckCircle2, Undo2 } from "lucide-react";
import { SectionLabel } from "./common";

/** Mirrors ExecutedActionRow (MenuBarView.swift). */
export function ExecutedSection({
  items,
  onUndo,
}: {
  items: MenuExecutedAction[];
  onUndo: (actionID: string) => void;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <SectionLabel>Executed</SectionLabel>
      <div className="flex flex-col gap-2">
        {items.map((action) => (
          <div key={action.id} className="flex items-center gap-2">
            {action.undone ? (
              <Undo2 className="size-3.5 shrink-0 text-warning" />
            ) : (
              <CheckCircle2 className="size-3.5 shrink-0 text-success" />
            )}
            <div className="min-w-0 flex-1">
              <p className="line-clamp-2 text-[12px] leading-snug">{action.summary}</p>
              {action.url ? <ExternalLink href={action.url}>{action.url}</ExternalLink> : null}
            </div>
            {action.canUndo ? (
              <Button size="sm" variant="outline" onClick={() => onUndo(action.id)} className="shrink-0">
                Undo
              </Button>
            ) : null}
          </div>
        ))}
      </div>
    </div>
  );
}
