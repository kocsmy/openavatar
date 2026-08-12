import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import type { MenuDecision, MenuDismissReason } from "@/lib/types/menu";
import { CircleCheck, CircleX } from "lucide-react";
import { BoundedRows, INTENT_ICON, ReasonMenu, SectionLabel } from "./common";

/** Mirrors MenuBarView's "Detected this call" / "From your last call" section. */
export function DetectedSection({
  title,
  items,
  confidenceThreshold,
  onPrepare,
  onMarkDone,
  onDismiss,
}: {
  title: string;
  items: MenuDecision[];
  confidenceThreshold: number;
  onPrepare: (decisionID: string) => void;
  onMarkDone: (decisionID: string) => void;
  onDismiss: (decisionID: string, reason: MenuDismissReason) => void;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <SectionLabel>{title}</SectionLabel>
      <BoundedRows count={items.length} rowHeight={76}>
        {items.map((decision) => (
          <DecisionRow
            key={decision.id}
            decision={decision}
            belowThreshold={decision.confidence < confidenceThreshold}
            onPrepare={() => onPrepare(decision.id)}
            onMarkDone={() => onMarkDone(decision.id)}
            onDismiss={(reason) => onDismiss(decision.id, reason)}
          />
        ))}
      </BoundedRows>
    </div>
  );
}

/** Mirrors DecisionRow (MenuBarView.swift). Below the confidence threshold →
 * greyed out, never auto-executed (spec §4.4). */
function DecisionRow({
  decision,
  belowThreshold,
  onPrepare,
  onMarkDone,
  onDismiss,
}: {
  decision: MenuDecision;
  belowThreshold: boolean;
  onPrepare: () => void;
  onMarkDone: () => void;
  onDismiss: (reason: MenuDismissReason) => void;
}) {
  const Icon = INTENT_ICON[decision.intent];
  return (
    <div className={cn("flex items-start gap-2 rounded-lg bg-card p-2.5 shadow-sm", belowThreshold && "opacity-60")}>
      <Icon className={cn("mt-0.5 size-4 shrink-0", belowThreshold ? "text-muted-foreground" : "text-primary")} />
      <div className="min-w-0 flex-1">
        <p className={cn("text-[12.5px] leading-snug", belowThreshold && "text-muted-foreground")}>
          {decision.summary}
        </p>
        <p className="mt-0.5 line-clamp-2 text-[11px] text-muted-foreground/60">“{decision.quote}”</p>
      </div>
      <Button size="sm" variant="secondary" onClick={onPrepare} className="shrink-0">
        Prepare
      </Button>
      <button
        onClick={onMarkDone}
        title="Done — I already did this myself"
        className="shrink-0 rounded p-1 text-success transition-colors hover:bg-accent/60"
      >
        <CircleCheck className="size-3.5" />
      </button>
      <ReasonMenu
        labelKey="decisionLabel"
        title="Dismiss with a reason"
        onSelect={onDismiss}
        triggerClassName="shrink-0 rounded p-1 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
      >
        <CircleX className="size-3.5" />
      </ReasonMenu>
    </div>
  );
}
