import * as React from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import type { MenuApproval, MenuDismissReason, MenuJSONValue } from "@/lib/types/menu";
import { ReasonMenu, RiskBadge, SectionLabel } from "./common";

// Keys whose string values edit as a textarea even when short — mirrors
// ApprovalCard.longKeys (MenuBarView.swift).
const LONG_KEYS = new Set(["body", "description", "message", "detail", "text", "content", "comment", "notes"]);

interface EditField {
  key: string;
  value: string;
  isString: boolean;
  multiline: boolean;
}

/** Mirrors MenuBarView's "Waiting for your approval" section (spec §4.8). */
export function ApprovalsSection({
  items,
  onApprove,
  onDismiss,
  onSaveEdit,
}: {
  items: MenuApproval[];
  onApprove: (approvalID: string) => void;
  onDismiss: (decisionID: string, reason: MenuDismissReason) => void;
  onSaveEdit: (approvalID: string, stepID: string, args: Record<string, MenuJSONValue>) => void;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <SectionLabel>Waiting for your approval</SectionLabel>
      <div className="flex flex-col gap-2">
        {items.map((approval) => (
          <ApprovalCard
            key={approval.id}
            approval={approval}
            onApprove={() => onApprove(approval.id)}
            onDismiss={(reason) => onDismiss(approval.decision.id, reason)}
            onSaveEdit={(stepID, args) => onSaveEdit(approval.id, stepID, args)}
          />
        ))}
      </div>
    </div>
  );
}

/** Mirrors ApprovalViews.swift's ApprovalCard, including inline argument editing. */
function ApprovalCard({
  approval,
  onApprove,
  onDismiss,
  onSaveEdit,
}: {
  approval: MenuApproval;
  onApprove: () => void;
  onDismiss: (reason: MenuDismissReason) => void;
  onSaveEdit: (stepID: string, args: Record<string, MenuJSONValue>) => void;
}) {
  const [isEditing, setIsEditing] = React.useState(false);
  const [fields, setFields] = React.useState<EditField[]>([]);
  const [editError, setEditError] = React.useState<string | null>(null);
  const step = approval.plan.steps[0];

  const beginEdit = () => {
    if (!step) return;
    setEditError(null);
    setFields(
      Object.entries(step.arguments)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, value]) => {
          if (typeof value === "string") {
            const multiline = value.length > 48 || value.includes("\n") || LONG_KEYS.has(key.toLowerCase());
            return { key, value, isString: true, multiline };
          }
          // Non-string: edit as JSON so arrays/numbers survive round-trip.
          return { key, value: JSON.stringify(value), isString: false, multiline: true };
        }),
    );
    setIsEditing(true);
  };

  const applyEdit = () => {
    if (!step) return;
    const next: Record<string, MenuJSONValue> = { ...step.arguments };
    for (const field of fields) {
      if (field.isString) {
        next[field.key] = field.value;
        continue;
      }
      try {
        next[field.key] = JSON.parse(field.value) as MenuJSONValue;
      } catch {
        setEditError(`"${field.key}" isn't valid — check the format and try again.`);
        return;
      }
    }
    onSaveEdit(step.id, next);
    setIsEditing(false);
  };

  return (
    <div className="flex flex-col gap-1.5 rounded-lg bg-card p-2.5 shadow-sm">
      <div className="flex items-center gap-2">
        <RiskBadge risk={approval.plan.riskClass} />
        <p className="min-w-0 flex-1 text-[12.5px] font-medium leading-snug line-clamp-2">
          {approval.plan.preview.title}
        </p>
      </div>

      <div
        data-selectable
        className="max-h-36 overflow-y-auto whitespace-pre-wrap break-words rounded-md bg-muted/70 p-1.5 font-mono text-[11px] leading-relaxed"
      >
        {approval.plan.preview.detail}
      </div>

      {isEditing ? (
        <div className="flex flex-col gap-2">
          {fields.map((field, i) => (
            <div key={field.key} className="flex flex-col gap-1">
              <label className="text-[10.5px] font-semibold text-muted-foreground">{field.key}</label>
              {field.multiline ? (
                <Textarea
                  value={field.value}
                  className="h-17 text-[12px]"
                  onChange={(e) =>
                    setFields((fs) => fs.map((f, fi) => (fi === i ? { ...f, value: e.target.value } : f)))
                  }
                />
              ) : (
                <Input
                  value={field.value}
                  className="text-[12px]"
                  onChange={(e) =>
                    setFields((fs) => fs.map((f, fi) => (fi === i ? { ...f, value: e.target.value } : f)))
                  }
                />
              )}
            </div>
          ))}
          {editError ? <p className="text-[11px] text-destructive">{editError}</p> : null}
          <div className="flex gap-2">
            <Button size="sm" onClick={applyEdit}>
              Save changes
            </Button>
            <Button size="sm" variant="outline" onClick={() => setIsEditing(false)}>
              Cancel
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex items-center gap-2">
          <Button size="sm" onClick={onApprove}>
            Approve
          </Button>
          <Button size="sm" variant="outline" onClick={beginEdit}>
            Edit
          </Button>
          <ReasonMenu
            labelKey="approvalLabel"
            onSelect={onDismiss}
            triggerClassName="h-6.5 rounded-md border border-input bg-card px-2.5 text-[12px] shadow-sm transition-colors hover:bg-accent"
          >
            Dismiss
          </ReasonMenu>
          {approval.edited ? <span className="text-[10.5px] text-warning">edited</span> : null}
        </div>
      )}
    </div>
  );
}
