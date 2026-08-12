import * as React from "react";
import { bridge } from "@/lib/bridge";
import { EmptyState, Toolbar, useLive } from "@/components/live";
import type { FollowUp } from "@/lib/types/followups";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";
import { AlertCircle, BellOff, CheckCircle2, Clock, RefreshCw, Trash2 } from "lucide-react";

/**
 * Friendly due-time string, ported from FollowUpFormatter.due (Sources/OpenAvatar/UI/FollowUpViews.swift):
 * "Today at 3:00 PM", "Tomorrow at 9:00 AM", "Overdue · Jul 14, 9:00 AM", or a
 * full date further out.
 */
function formatDue(iso: string): string {
  const due = new Date(iso);
  if (Number.isNaN(due.getTime())) return "";
  const now = new Date();
  const time = due.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  if (due < now) {
    return `Overdue · ${due.toLocaleDateString(undefined, { month: "short", day: "numeric" })}, ${time}`;
  }
  const sameDay = (a: Date, b: Date) => a.toDateString() === b.toDateString();
  if (sameDay(due, now)) return `Today at ${time}`;
  const tomorrow = new Date(now);
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (sameDay(due, tomorrow)) return `Tomorrow at ${time}`;
  const daysOut = Math.round((due.getTime() - now.getTime()) / 86_400_000);
  if (daysOut < 7) return `${due.toLocaleDateString(undefined, { weekday: "long" })}, ${time}`;
  return `${due.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}, ${time}`;
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="mb-1.5 px-0.5 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
      {children}
    </p>
  );
}

function FollowUpRow({
  followUp,
  isDone,
  onComplete,
  onSnooze,
  onDelete,
}: {
  followUp: FollowUp;
  isDone: boolean;
  onComplete?: () => void;
  onSnooze?: (days: number) => void;
  onDelete: () => void;
}) {
  const isOverdue = !isDone && new Date(followUp.dueAt) < new Date();
  // Snooze is a menu of actions, not a persisted choice — remounting via key
  // after each pick returns the trigger to its "Snooze" placeholder.
  const [snoozeNonce, setSnoozeNonce] = React.useState(0);

  return (
    <div className="flex items-start gap-3 rounded-lg border border-border bg-card px-3 py-2.5">
      {isDone ? (
        <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-success" />
      ) : isOverdue ? (
        <AlertCircle className="mt-0.5 size-4 shrink-0 text-warning" />
      ) : (
        <Clock className="mt-0.5 size-4 shrink-0 text-primary" />
      )}

      <div className="min-w-0 flex-1">
        <p className={cn("text-[13px]", isDone && "text-muted-foreground line-through")}>
          {followUp.title}
        </p>
        <p className={cn("text-xs", isOverdue ? "text-warning" : "text-muted-foreground")}>
          {formatDue(followUp.dueAt)}
        </p>
      </div>

      <div className="flex shrink-0 items-center gap-1.5">
        {!isDone && (
          <>
            <Button size="sm" variant="secondary" onClick={() => onComplete?.()}>
              Done
            </Button>
            <Select
              key={snoozeNonce}
              onValueChange={(v) => {
                onSnooze?.(Number(v));
                setSnoozeNonce((n) => n + 1);
              }}
            >
              <SelectTrigger className="h-6.5 w-auto gap-1 px-2 text-xs" aria-label="Snooze">
                <SelectValue placeholder="Snooze" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="1">Tomorrow</SelectItem>
                <SelectItem value="3">In 3 days</SelectItem>
                <SelectItem value="7">Next week</SelectItem>
              </SelectContent>
            </Select>
          </>
        )}
        <Button size="icon" variant="ghost" title="Delete" aria-label="Delete" onClick={onDelete}>
          <Trash2 className="size-3.5" />
        </Button>
      </div>
    </div>
  );
}

export function FollowUpsPage() {
  const { data, loading, reload } = useLive("followups.list", {}, { topics: ["state", "followups"] });

  const scheduled = data?.scheduled ?? [];
  const done = data?.done ?? [];
  const isEmpty = !loading && scheduled.length === 0 && done.length === 0;

  const complete = (id: string) => void bridge("followups.complete", { id });
  const snooze = (id: string, days: number) => void bridge("followups.snooze", { id, days });
  const remove = (id: string) => void bridge("followups.delete", { id });

  return (
    <div className="flex min-h-full flex-col">
      <Toolbar
        title="Follow-ups"
        subtitle={data ? `${scheduled.length} upcoming · ${done.length} done` : undefined}
      >
        <Button size="icon" variant="ghost" title="Refresh" aria-label="Refresh" onClick={() => reload()}>
          <RefreshCw className="size-3.5" />
        </Button>
      </Toolbar>

      <div className="mx-auto w-full max-w-2xl flex-1 px-6 py-6">
        <p className="mb-4 text-xs leading-relaxed text-muted-foreground">
          Things you said you&rsquo;d revisit. When a call mentions a future item, confirm it in the
          post-call review — OpenAvatar then reminds you at its due time, even if the app was quit.
        </p>

        <div className="mb-5 flex items-center justify-between rounded-lg border border-border bg-card px-3 py-2.5">
          <span className="text-[13px]">Capture follow-ups from calls</span>
          <Switch
            checked={data?.captureEnabled ?? true}
            disabled={!data}
            onCheckedChange={(enabled) => void bridge("followups.setCaptureEnabled", { enabled })}
          />
        </div>

        {isEmpty ? (
          <EmptyState
            icon={BellOff}
            title="No follow-ups yet"
            description="Confirm a follow-up in the post-call review and it'll appear here."
          />
        ) : (
          <div className="flex flex-col gap-5">
            {scheduled.length > 0 && (
              <div>
                <SectionLabel>Upcoming</SectionLabel>
                <div className="flex flex-col gap-1.5">
                  {scheduled.map((f) => (
                    <FollowUpRow
                      key={f.id}
                      followUp={f}
                      isDone={false}
                      onComplete={() => complete(f.id)}
                      onSnooze={(days) => snooze(f.id, days)}
                      onDelete={() => remove(f.id)}
                    />
                  ))}
                </div>
              </div>
            )}
            {done.length > 0 && (
              <div>
                <SectionLabel>Done</SectionLabel>
                <div className="flex flex-col gap-1.5">
                  {done.map((f) => (
                    <FollowUpRow key={f.id} followUp={f} isDone onDelete={() => remove(f.id)} />
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
