import * as React from "react";
import { bridge } from "@/lib/bridge";
import { EmptyState, Toolbar, useLive } from "@/components/live";
import type { MeetingSummary } from "@/lib/types/meetings";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { CalendarDays, ChevronRight, RefreshCw, Search, Trash2 } from "lucide-react";
import { MeetingDetailPane } from "./MeetingDetail";

/*
 * Ports of TranscriptViews.swift's TranscriptFormatter / MeetingFormat: pure
 * display logic with no secrets in it, so it lives on this side of the bridge
 * rather than being round-tripped through Swift. MeetingDetail.tsx reuses
 * these too, so they're exported rather than duplicated.
 */

/** Best human name for a meeting — mirrors CallRecord.displayTitle exactly. */
export function displayTitle(m: Pick<MeetingSummary, "title" | "app">): string {
  if (m.title && m.title.trim()) return m.title;
  if (m.app && m.app.trim()) return /call/i.test(m.app) ? m.app : `${m.app} call`;
  return "Call";
}

/** "N min" under an hour, "H h M min" past it — mirrors MeetingFormat.duration. */
export function meetingDuration(startedAtISO: string, endedAtISO: string): string {
  const minutes = Math.max(
    1,
    Math.floor((new Date(endedAtISO).getTime() - new Date(startedAtISO).getTime()) / 60_000),
  );
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

/** Splits the legacy ";"-joined digest back into scannable bullets. */
export function digestBullets(digest: string): string[] {
  return digest
    .split(";")
    .map((s) => s.trim())
    .map((s) => (s.endsWith(".") ? s.slice(0, -1) : s))
    .filter((s) => s.length > 0);
}

export function formatDateTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

/** Deterministic per-voice color, matching TranscriptFormatter's djb2 bucketing. */
const SPEAKER_PALETTE = [
  "text-blue-500 dark:text-blue-400",
  "text-emerald-500 dark:text-emerald-400",
  "text-orange-500 dark:text-orange-400",
  "text-purple-500 dark:text-purple-400",
  "text-pink-500 dark:text-pink-400",
  "text-teal-500 dark:text-teal-400",
  "text-indigo-500 dark:text-indigo-400",
  "text-amber-700 dark:text-amber-500",
];

export function speakerColorClass(speakerID: string): string {
  let hash = 5381;
  for (let i = 0; i < speakerID.length; i++) {
    hash = (Math.imul(hash, 33) ^ speakerID.charCodeAt(i)) >>> 0;
  }
  return SPEAKER_PALETTE[hash % SPEAKER_PALETTE.length];
}

export function segmentColorClass(seg: { source: string; speakerID: string | null; speaker: string | null }): string {
  if (seg.source === "mic") return "text-primary";
  if (seg.speakerID) return speakerColorClass(seg.speakerID);
  const trailingNumber = seg.speaker?.match(/(\d+)$/)?.[1];
  if (trailingNumber) return SPEAKER_PALETTE[(Number(trailingNumber) - 1) % SPEAKER_PALETTE.length];
  return "text-muted-foreground";
}

function isSameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function dayLabel(day: Date): string {
  const today = new Date();
  if (isSameDay(day, today)) return "Today";
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);
  if (isSameDay(day, yesterday)) return "Yesterday";
  return day.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function dayKey(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

/**
 * The library: a day-grouped list on the left, the selected meeting's
 * Summary/Actions/Transcript on the right. A master/detail split reads
 * better in a 1120px window than the native push-navigation did, so unlike
 * MeetingsTab this never replaces itself with MeetingDetailView — it just
 * fills the right pane.
 */
export function MeetingsPage() {
  const { data, loading, reload } = useLive("meetings.list", {}, { topics: ["state", "meetings"] });
  const [query, setQuery] = React.useState("");
  const [selectedID, setSelectedID] = React.useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = React.useState<MeetingSummary | null>(null);
  const [deleting, setDeleting] = React.useState(false);

  const meetings = React.useMemo(
    () => (data?.meetings ?? []).slice().sort((a, b) => new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime()),
    [data],
  );

  const filtered = React.useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return meetings;
    return meetings.filter((m) =>
      [displayTitle(m), m.app ?? "", m.summary ?? ""].some((s) => s.toLowerCase().includes(q)),
    );
  }, [meetings, query]);

  const groups = React.useMemo(() => {
    const byDay = new Map<string, { day: Date; items: MeetingSummary[] }>();
    for (const m of filtered) {
      const key = dayKey(m.startedAt);
      const entry = byDay.get(key);
      if (entry) entry.items.push(m);
      else byDay.set(key, { day: new Date(m.startedAt), items: [m] });
    }
    return [...byDay.entries()].sort((a, b) => b[1].day.getTime() - a[1].day.getTime());
  }, [filtered]);

  async function confirmDelete() {
    if (!pendingDelete) return;
    setDeleting(true);
    try {
      await bridge("meetings.delete", { callID: pendingDelete.id });
      if (selectedID === pendingDelete.id) setSelectedID(null);
      setPendingDelete(null);
      reload();
    } finally {
      setDeleting(false);
    }
  }

  return (
    <div className="flex h-full min-h-0">
      <div className="flex w-80 shrink-0 flex-col border-r border-border">
        <Toolbar title="Meetings" subtitle={meetings.length ? `${meetings.length} recorded` : undefined}>
          <Button variant="ghost" size="icon" onClick={() => reload()} aria-label="Refresh">
            <RefreshCw className="size-3.5" />
          </Button>
        </Toolbar>

        <div className="border-b border-border p-2.5">
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search meetings…"
              className="pl-8"
            />
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto">
          {!loading && meetings.length === 0 ? (
            <EmptyState
              icon={CalendarDays}
              title="No meetings yet"
              description="Meetings appear here after your first call."
            />
          ) : !loading && filtered.length === 0 ? (
            <EmptyState title="No matches" description="Try a different search." />
          ) : (
            <div className="flex flex-col gap-4 p-2.5">
              {groups.map(([key, group]) => (
                <div key={key} className="flex flex-col gap-0.5">
                  <div className="px-1.5 pb-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
                    {dayLabel(group.day)}
                  </div>
                  {group.items.map((m) => (
                    <MeetingRow
                      key={m.id}
                      meeting={m}
                      selected={m.id === selectedID}
                      onSelect={() => setSelectedID(m.id)}
                      onDelete={() => setPendingDelete(m)}
                    />
                  ))}
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {selectedID ? (
          <MeetingDetailPane
            key={selectedID}
            callID={selectedID}
            onDeleted={() => {
              setSelectedID(null);
              reload();
            }}
          />
        ) : (
          <EmptyState
            icon={CalendarDays}
            title="Select a meeting"
            description="Pick a call on the left to see its summary, actions, and transcript."
          />
        )}
      </div>

      <Dialog open={pendingDelete != null} onOpenChange={(open) => !open && setPendingDelete(null)}>
        <DialogContent>
          <DialogTitle>Delete “{pendingDelete ? displayTitle(pendingDelete) : "meeting"}”?</DialogTitle>
          <DialogDescription>
            The transcript, notes, and detected actions are removed. This can't be undone.
          </DialogDescription>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPendingDelete(null)}>
              Cancel
            </Button>
            <Button variant="destructive" disabled={deleting} onClick={() => void confirmDelete()}>
              Delete meeting
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function MeetingRow({
  meeting,
  selected,
  onSelect,
  onDelete,
}: {
  meeting: MeetingSummary;
  selected: boolean;
  onSelect: () => void;
  onDelete: () => void;
}) {
  const time = new Date(meeting.startedAt).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  const parts = [time];
  if (meeting.endedAt) parts.push(meetingDuration(meeting.startedAt, meeting.endedAt));
  if (meeting.summary) parts.push(meeting.summary);

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(e) => e.key === "Enter" && onSelect()}
      className={cn(
        "group flex cursor-default items-center gap-1.5 rounded-md px-2.5 py-2 text-left transition-colors",
        selected ? "bg-primary/10" : "hover:bg-accent/60",
      )}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <span className="truncate text-[13px] font-medium">{displayTitle(meeting)}</span>
          {meeting.app ? (
            <Badge variant="secondary" className="shrink-0">
              {meeting.app}
            </Badge>
          ) : null}
        </div>
        <p className="truncate text-xs text-muted-foreground">{parts.join(" · ")}</p>
      </div>
      <button
        onClick={(e) => {
          e.stopPropagation();
          onDelete();
        }}
        className="shrink-0 rounded p-1 text-muted-foreground opacity-0 transition-opacity hover:bg-destructive/10 hover:text-destructive group-hover:opacity-100"
        aria-label="Delete meeting"
        title="Delete meeting…"
      >
        <Trash2 className="size-3.5" />
      </button>
      <ChevronRight className="size-3.5 shrink-0 text-muted-foreground/40" />
    </div>
  );
}
