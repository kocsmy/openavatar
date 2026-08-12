import * as React from "react";
import { cn } from "@/lib/utils";
import type { MenuDismissReason, MenuIntent, MenuRiskClass } from "@/lib/types/menu";
import { Code2, GitMerge, ListChecks, Mail, MessageSquare, Sparkles } from "lucide-react";

/** Small caps section header, matching DSSectionLabel. */
export function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="px-0.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground/70">
      {children}
    </p>
  );
}

/**
 * Shows up to `visibleCap` rows at full height; beyond that the list scrolls
 * inside a capped region (a peek of the next row signals there's more).
 * Mirrors MenuBarView.boundedRows.
 */
export function BoundedRows({
  count,
  rowHeight,
  visibleCap = 3,
  children,
}: {
  count: number;
  rowHeight: number;
  visibleCap?: number;
  children: React.ReactNode;
}) {
  const capped = count > visibleCap;
  return (
    <div
      className={cn("flex flex-col gap-2", capped && "overflow-y-auto pr-0.5")}
      style={capped ? { maxHeight: rowHeight * visibleCap } : undefined}
    >
      {children}
    </div>
  );
}

/** A full-width hoverable row for navigational actions (DSRow style: .ghost). */
export const GhostRow = React.forwardRef<
  HTMLButtonElement,
  { onClick: () => void; title?: string; className?: string; children: React.ReactNode }
>(({ onClick, title, className, children }, ref) => (
  <button
    ref={ref}
    onClick={onClick}
    title={title}
    className={cn(
      "flex w-full items-center rounded-md px-2 py-1.5 text-left transition-colors hover:bg-accent/60",
      className,
    )}
  >
    {children}
  </button>
));
GhostRow.displayName = "GhostRow";

const RISK_TONE: Record<MenuRiskClass, string> = {
  read: "bg-success/12 text-success",
  draft: "bg-primary/12 text-primary",
  write: "bg-warning/14 text-warning",
  destructive: "bg-destructive/12 text-destructive",
};

export function RiskBadge({ risk }: { risk: MenuRiskClass }) {
  return (
    <span
      className={cn(
        "shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wide",
        RISK_TONE[risk],
      )}
    >
      {risk}
    </span>
  );
}

/** Mirrors DecisionRow.icon (MenuBarView.swift). */
export const INTENT_ICON: Record<MenuIntent, React.ComponentType<{ className?: string }>> = {
  create_ticket: ListChecks,
  code_change: Code2,
  send_message: MessageSquare,
  send_email: Mail,
  merge_pr: GitMerge,
  other: Sparkles,
};

/**
 * The two dismiss-reason wordings from the SwiftUI source: ApprovalCard used
 * DismissReason.displayName ("Other reason"); DecisionRow's local
 * `reasonLabel` used "Dismiss" for the same case. Preserved verbatim.
 */
export const DISMISS_REASONS: {
  value: MenuDismissReason;
  approvalLabel: string;
  decisionLabel: string;
}[] = [
  { value: "wrong_transcription", approvalLabel: "Wrong transcription", decisionLabel: "Wrong transcription" },
  { value: "wrong_intent", approvalLabel: "Wrong intent", decisionLabel: "Wrong intent" },
  { value: "not_actionable", approvalLabel: "Not actionable", decisionLabel: "Not actionable" },
  { value: "duplicate", approvalLabel: "Duplicate", decisionLabel: "Duplicate" },
  { value: "other", approvalLabel: "Other reason", decisionLabel: "Dismiss" },
];

/** Dismiss-with-reason popup used by both ApprovalCard and DecisionRow — no
 * dropdown-menu primitive exists in ui/, so this is a minimal local one. */
export function ReasonMenu({
  labelKey,
  onSelect,
  title,
  triggerClassName,
  children,
}: {
  labelKey: "approvalLabel" | "decisionLabel";
  onSelect: (reason: MenuDismissReason) => void;
  title?: string;
  triggerClassName?: string;
  children: React.ReactNode;
}) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div className="relative shrink-0" ref={ref}>
      <button onClick={() => setOpen((o) => !o)} title={title} className={triggerClassName}>
        {children}
      </button>
      {open ? (
        <div className="absolute right-0 top-full z-20 mt-1 min-w-36 overflow-hidden rounded-md border border-border bg-popover py-1 shadow-md">
          {DISMISS_REASONS.map((r) => (
            <button
              key={r.value}
              onClick={() => {
                setOpen(false);
                onSelect(r.value);
              }}
              className="block w-full px-2.5 py-1.5 text-left text-[12px] transition-colors hover:bg-accent/60"
            >
              {r[labelKey]}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}
