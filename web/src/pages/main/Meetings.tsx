import * as React from "react";
import { bridge, openStream } from "@/lib/bridge";
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
import { AskBar, ChatThread, historyOf, type ChatItem } from "@/components/chat";
import { cn } from "@/lib/utils";
import { CalendarDays, ChevronRight, RefreshCw, Search, Trash2 } from "lucide-react";
import { MeetingDetailPane } from "./MeetingDetail";
import { LiveCallPane, LiveCallRow } from "./LiveCall";

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
/** Selection sentinel for the pinned live row — deliberately not a call id. */
const LIVE_ID = "__live__";

export function MeetingsPage() {
  const { data, loading, reload } = useLive("meetings.list", {}, { topics: ["state", "meetings"] });
  const { data: callState } = useLive("call.state", {}, { topics: ["state"] });
  const [query, setQuery] = React.useState("");
  const [selectedID, setSelectedID] = React.useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = React.useState<MeetingSummary | null>(null);
  const [deleting, setDeleting] = React.useState(false);
  const [thread, setThread] = React.useState<ChatItem[]>([]);
  const [asking, setAsking] = React.useState(false);

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

  /*
   * What's happening right now: a call in progress, or an upcoming meeting
   * opened to write notes ahead of time. Both used to be a separate window;
   * here they're a pinned row above the history, because a live call is just
   * the newest meeting in it. Mode "ended" is deliberately not live — that
   * call has a real row of its own by then.
   */
  const live = callState && callState.mode !== "ended" ? callState : null;
  const liveTargetID = live?.targetId ?? null;
  const endedCallID = callState?.mode === "ended" ? (callState.ended?.callID ?? null) : null;

  // Open on the newest meeting, the way a mail client does. The native list
  // pushed to a detail view and had nothing to show until you picked one;
  // side by side, an empty half-window is just wasted space.
  React.useEffect(() => {
    if (selectedID === null && meetings.length > 0) setSelectedID(meetings[0].id);
  }, [meetings, selectedID]);

  /*
   * Follow the call. The window shows itself when one starts, so it should
   * land on the call rather than on whatever was last read — but only once
   * per call, or a mid-call refetch would yank the view back every few
   * hundred milliseconds while someone is reading an old meeting.
   */
  const followed = React.useRef<string | null>(null);
  React.useEffect(() => {
    if (!liveTargetID || followed.current === liveTargetID) return;
    followed.current = liveTargetID;
    setSelectedID(LIVE_ID);
  }, [liveTargetID]);

  // The handover, which used to be a window swapping its own contents: once
  // the call ends, move to its finished page — unless the user has already
  // navigated somewhere else themselves.
  React.useEffect(() => {
    if (!endedCallID) return;
    setSelectedID((cur) => (cur === null || cur === LIVE_ID ? endedCallID : cur));
  }, [endedCallID]);

  // A preview that got dismissed without becoming a call leaves the pinned
  // row selected but gone; fall back to the newest meeting.
  const isLive = live !== null;
  React.useEffect(() => {
    if (selectedID === LIVE_ID && !isLive && !endedCallID) setSelectedID(null);
  }, [selectedID, isLive, endedCallID]);

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

  /**
   * The same box does both jobs. Typing filters the list on the spot, which is
   * what you want when you half-remember a title; pressing Enter hands the
   * question to the model, which decides which calls to actually read. One
   * input, because "search" and "ask" are the same intent at different levels
   * of precision.
   */
  async function askLibrary(question: string) {
    const history = historyOf(thread);
    setThread((t) => [...t, { role: "user", content: question }]);
    setAsking(true);
    // Deltas only start once the picker has chosen what to read, so the
    // "reading the transcript" row genuinely covers that first stage.
    const stream = openStream((delta) =>
      setThread((t) => {
        const last = t[t.length - 1];
        if (!last || last.role !== "assistant" || !last.streaming) {
          return [...t, { role: "assistant", content: delta, streaming: true }];
        }
        return [...t.slice(0, -1), { ...last, content: last.content + delta }];
      }),
    );
    try {
      const res = await bridge("meetings.search", { query: question, history, streamID: stream.id });
      setThread((t) => {
        const done: ChatItem = { role: "assistant", content: res.answer, callIDs: res.callIDs };
        const last = t[t.length - 1];
        return last?.streaming ? [...t.slice(0, -1), done] : [...t, done];
      });
    } catch (e) {
      setThread((t) => {
        const failed: ChatItem = {
          role: "assistant",
          content: e instanceof Error ? e.message : String(e),
          failed: true,
        };
        const last = t[t.length - 1];
        return last?.streaming ? [...t.slice(0, -1), failed] : [...t, failed];
      });
    } finally {
      stream.close();
      setAsking(false);
    }
  }

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

        <div className="flex flex-col gap-1 border-b border-border p-2.5">
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key !== "Enter" || !query.trim() || asking) return;
                e.preventDefault();
                void askLibrary(query.trim());
                setQuery("");
              }}
              placeholder="Search meetings, or ask a question…"
              className="pl-8"
            />
          </div>
          {query.trim() ? (
            <p className="px-1 text-[11px] text-muted-foreground">
              <kbd className="rounded border border-border px-1 font-sans">↵</kbd> to ask across all meetings
            </p>
          ) : null}
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto">
          {live ? (
            <div className="flex flex-col gap-0.5 px-2.5 pt-2.5">
              <div className="px-1.5 pb-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
                {live.mode === "event" ? "Up next" : "Now"}
              </div>
              <LiveCallRow
                state={live}
                selected={selectedID === LIVE_ID}
                onSelect={() => setSelectedID(LIVE_ID)}
              />
            </div>
          ) : null}

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

      <div className="min-h-0 flex-1 overflow-hidden">
        {thread.length > 0 || asking ? (
          <LibraryAnswer
            thread={thread}
            asking={asking}
            meetings={meetings}
            onAsk={(q) => void askLibrary(q)}
            onClose={() => setThread([])}
            onOpenMeeting={(id) => {
              setSelectedID(id);
              setThread([]);
            }}
          />
        ) : selectedID === LIVE_ID && live ? (
          <LiveCallPane state={live} />
        ) : selectedID && selectedID !== LIVE_ID ? (
          // Rendered directly, not inside a scroller: the detail pane manages
          // its own scrolling so its ask composer can stay pinned at the
          // bottom, which needs a bounded height here.
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

/**
 * The answer side of library search. Takes the whole right pane rather than a
 * dropdown under the box, because an answer worth reading is a paragraph and
 * cites meetings you'll want to open — and opening one is a click on its chip.
 */
function LibraryAnswer({
  thread,
  asking,
  meetings,
  onAsk,
  onClose,
  onOpenMeeting,
}: {
  thread: ChatItem[];
  asking: boolean;
  meetings: MeetingSummary[];
  onAsk: (question: string) => void;
  onClose: () => void;
  onOpenMeeting: (callID: string) => void;
}) {
  return (
    <div className="flex h-full min-h-0 flex-col">
      <Toolbar title="Across your meetings" subtitle={`${meetings.length} searched`}>
        <Button variant="ghost" size="sm" onClick={onClose}>
          Done
        </Button>
      </Toolbar>
      <div className="min-h-0 flex-1 overflow-y-auto px-6 py-5">
        <div className="mx-auto max-w-2xl">
          <ChatThread
            thread={thread}
            busy={asking}
            renderCitations={(callIDs) => (
              <>
                {callIDs.map((id) => {
                  const meeting = meetings.find((m) => m.id === id);
                  if (!meeting) return null;
                  return (
                    <button
                      key={id}
                      onClick={() => onOpenMeeting(id)}
                      className="rounded-full border border-border px-2 py-0.5 text-[11px] text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
                      title="Open this meeting"
                    >
                      {displayTitle(meeting)} · {formatDateTime(meeting.startedAt)}
                    </button>
                  );
                })}
              </>
            )}
          />
        </div>
      </div>
      <div className="shrink-0 border-t border-border px-6 py-3">
        <div className="mx-auto max-w-2xl">
          <AskBar placeholder="Ask a follow-up" busy={asking} autoFocus onSubmit={onAsk} onClear={onClose} />
        </div>
      </div>
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
