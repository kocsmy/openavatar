import * as React from "react";
import { bridge, openStream } from "@/lib/bridge";
import { EmptyState } from "@/components/live";
import type {
  DecisionStatus,
  DismissReason,
  FollowUpStatus,
  MeetingDecision,
  MeetingDetail as MeetingDetailData,
  MeetingFollowUp,
  MeetingSpeaker,
} from "@/lib/types/meetings";
import { Badge, type BadgeProps } from "@/components/ui/badge";
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
import { Markdown } from "@/components/markdown";
import { cn } from "@/lib/utils";
import {
  Bell,
  CheckCircle2,
  ClipboardCopy,
  Download,
  ListChecks,
  Loader2,
  MoreHorizontal,
  Trash2,
  XCircle,
} from "lucide-react";
import { digestBullets, displayTitle, formatDateTime, meetingDuration, segmentColorClass } from "./Meetings";

type Pane = "summary" | "notes" | "actions" | "transcript";

const DISMISS_REASONS: { value: DismissReason; label: string }[] = [
  { value: "wrong_transcription", label: "Wrong transcription" },
  { value: "wrong_intent", label: "Wrong intent" },
  { value: "not_actionable", label: "Not actionable" },
  { value: "duplicate", label: "Duplicate" },
  { value: "other", label: "Other reason" },
];

function decisionBadge(status: DecisionStatus): { label: string; variant: BadgeProps["variant"] } {
  switch (status) {
    case "detected":
      return { label: "Needs review", variant: "warning" };
    case "approved":
    case "edited":
      return { label: "Approved", variant: "default" };
    case "executed":
      return { label: "Executed", variant: "success" };
    case "done_myself":
      return { label: "Done by you", variant: "default" };
    case "dismissed":
      return { label: "Dismissed", variant: "secondary" };
    case "reverted":
      return { label: "Reverted", variant: "secondary" };
  }
}

function followUpBadge(status: FollowUpStatus): { label: string; variant: BadgeProps["variant"] } {
  switch (status) {
    case "suggested":
      return { label: "Suggested", variant: "warning" };
    case "scheduled":
      return { label: "Scheduled", variant: "default" };
    case "done":
      return { label: "Done", variant: "success" };
    case "dismissed":
      return { label: "Dismissed", variant: "secondary" };
  }
}

// MARK: Small local dropdown/popover — no @radix-ui/react-dropdown-menu or
// -popover in package.json, so the header menu, the dismiss-reason picker,
// and the speaker editor all share this instead of a new dependency.

function useClickOutside(ref: React.RefObject<HTMLElement | null>, onOutside: () => void) {
  React.useEffect(() => {
    function handle(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) onOutside();
    }
    document.addEventListener("mousedown", handle);
    return () => document.removeEventListener("mousedown", handle);
  }, [ref, onOutside]);
}

function InlineMenu({
  trigger,
  align = "end",
  panelClassName,
  children,
}: {
  trigger: (toggle: () => void) => React.ReactNode;
  align?: "start" | "end";
  panelClassName?: string;
  children: (close: () => void) => React.ReactNode;
}) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);
  useClickOutside(ref, () => setOpen(false));
  return (
    <div className="relative" ref={ref}>
      {trigger(() => setOpen((v) => !v))}
      {open ? (
        <div
          className={cn(
            "absolute z-20 mt-1 min-w-48 rounded-md border border-border bg-popover p-1 text-popover-foreground shadow-md",
            align === "end" ? "right-0" : "left-0",
            panelClassName,
          )}
        >
          {children(() => setOpen(false))}
        </div>
      ) : null}
    </div>
  );
}

function MenuItem({
  children,
  onClick,
  destructive,
  disabled,
}: {
  children: React.ReactNode;
  onClick: () => void;
  destructive?: boolean;
  disabled?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-[13px] transition-colors disabled:pointer-events-none disabled:opacity-40",
        destructive ? "text-destructive hover:bg-destructive/10" : "hover:bg-accent",
      )}
    >
      {children}
    </button>
  );
}

// MARK: Speaker chip — click to rename, merge, or split (SpeakerChip port).

function SpeakerChip({
  profile,
  others,
  onRename,
  onMerge,
  onDetach,
}: {
  profile: MeetingSpeaker;
  others: MeetingSpeaker[];
  onRename: (name: string | null) => void;
  onMerge: (targetID: string) => void;
  onDetach: () => void;
}) {
  const label = profile.name ?? `Speaker ${profile.ordinal}`;
  const isNamed = Boolean(profile.name && profile.name.trim());
  const [draft, setDraft] = React.useState(profile.name ?? "");

  return (
    <InlineMenu
      align="start"
      panelClassName="w-64 p-3"
      trigger={(toggle) => (
        <button
          onClick={() => {
            setDraft(profile.name ?? "");
            toggle();
          }}
          className="flex shrink-0 items-center gap-1.5 rounded-full bg-secondary px-2.5 py-1 text-[12px] font-medium transition-colors hover:bg-accent"
          title="Rename, merge, or split this voice"
        >
          <span className={cn("size-2 rounded-full", segmentColorClass({ source: "system", speakerID: profile.id, speaker: null }).replace("text-", "bg-"))} />
          {label}
        </button>
      )}
    >
      {(close) => (
        <div className="flex flex-col gap-3">
          <p className="text-[13px] font-semibold">Who is this?</p>
          <div className="flex items-center gap-1.5">
            <Input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="Name"
              className="h-7"
              onKeyDown={(e) => {
                if (e.key === "Enter" && draft.trim()) {
                  onRename(draft);
                  close();
                }
              }}
            />
            <Button
              size="sm"
              disabled={!draft.trim()}
              onClick={() => {
                onRename(draft);
                close();
              }}
            >
              Save
            </Button>
          </div>
          <div className="flex flex-wrap items-center gap-1.5">
            {isNamed ? (
              <Button
                size="sm"
                variant="outline"
                onClick={() => {
                  onRename(null);
                  close();
                }}
              >
                Clear name
              </Button>
            ) : null}
            <Button
              size="sm"
              variant="outline"
              onClick={() => {
                onDetach();
                close();
              }}
              title="Wrong person? Move this call's voice to a new, separate speaker"
            >
              Not them
            </Button>
          </div>
          {others.length > 0 ? (
            <div className="flex flex-col gap-1 border-t border-border pt-2">
              <p className="text-[11px] text-muted-foreground">Merge into…</p>
              {others.map((o) => (
                <MenuItem
                  key={o.id}
                  onClick={() => {
                    onMerge(o.id);
                    close();
                  }}
                >
                  {o.name ?? `Speaker ${o.ordinal}`}
                </MenuItem>
              ))}
            </div>
          ) : null}
          <p className="text-[11px] text-muted-foreground">
            {profile.sampleCount} utterances · a name sticks to this voice across calls
          </p>
        </div>
      )}
    </InlineMenu>
  );
}

// MARK: Action rows

function ActionRow({
  icon,
  title,
  detail,
  trailing,
}: {
  icon: React.ReactNode;
  title: string;
  detail?: string | null;
  trailing: React.ReactNode;
}) {
  return (
    <div className="flex items-start gap-3 rounded-lg bg-card p-3 shadow-sm">
      <div className="mt-0.5 text-primary">{icon}</div>
      <div className="min-w-0 flex-1">
        <p className="text-[13px]">{title}</p>
        {detail ? <p className="line-clamp-2 text-xs text-muted-foreground">{detail}</p> : null}
      </div>
      <div className="flex shrink-0 items-center gap-1.5">{trailing}</div>
    </div>
  );
}

function DecisionRow({ decision, callID, onChanged }: { decision: MeetingDecision; callID: string; onChanged: () => void }) {
  if (decision.status !== "detected") {
    const badge = decisionBadge(decision.status);
    return (
      <ActionRow
        icon={<ListChecks className="size-4" />}
        title={decision.summary}
        detail={decision.quote}
        trailing={<Badge variant={badge.variant}>{badge.label}</Badge>}
      />
    );
  }
  return (
    <ActionRow
      icon={<ListChecks className="size-4" />}
      title={decision.summary}
      detail={decision.quote}
      trailing={
        <>
          <Button
            size="sm"
            variant="outline"
            onClick={() => void bridge("meetings.prepareDecision", { callID, decisionID: decision.id }).then(onChanged)}
          >
            Prepare
          </Button>
          <button
            onClick={() => void bridge("meetings.markDecisionDone", { callID, decisionID: decision.id }).then(onChanged)}
            className="rounded p-1 text-success transition-colors hover:bg-success/10"
            title="Done — I already did this myself"
          >
            <CheckCircle2 className="size-4" />
          </button>
          <InlineMenu
            trigger={(toggle) => (
              <button onClick={toggle} className="rounded p-1 text-muted-foreground transition-colors hover:bg-accent" title="Dismiss with a reason">
                <XCircle className="size-4" />
              </button>
            )}
          >
            {(close) => (
              <>
                {DISMISS_REASONS.map((r) => (
                  <MenuItem
                    key={r.value}
                    onClick={() => {
                      void bridge("meetings.dismissDecision", { callID, decisionID: decision.id, reason: r.value }).then(onChanged);
                      close();
                    }}
                  >
                    {r.label}
                  </MenuItem>
                ))}
              </>
            )}
          </InlineMenu>
        </>
      }
    />
  );
}

function FollowUpRow({ followUp, callID, onChanged }: { followUp: MeetingFollowUp; callID: string; onChanged: () => void }) {
  if (followUp.status !== "suggested") {
    const badge = followUpBadge(followUp.status);
    return (
      <ActionRow
        icon={<Bell className="size-4" />}
        title={followUp.title}
        detail={`Due ${formatDateTime(followUp.dueAt)}`}
        trailing={<Badge variant={badge.variant}>{badge.label}</Badge>}
      />
    );
  }
  return (
    <ActionRow
      icon={<Bell className="size-4" />}
      title={followUp.title}
      detail={`Due ${formatDateTime(followUp.dueAt)}`}
      trailing={
        <>
          <Button
            size="sm"
            onClick={() => void bridge("meetings.confirmFollowUp", { callID, followUpID: followUp.id }).then(onChanged)}
          >
            Remind me
          </Button>
          <button
            onClick={() => void bridge("meetings.dismissFollowUp", { callID, followUpID: followUp.id }).then(onChanged)}
            className="rounded p-1 text-muted-foreground transition-colors hover:bg-accent"
            title="Dismiss"
          >
            <XCircle className="size-4" />
          </button>
        </>
      }
    />
  );
}

/**
 * The user's own notes. Editable here and not only in the call window: the
 * meeting you wrote notes for is exactly the one you want to add to once it's
 * over. Autosaves on a short debounce and on blur, so there's no Save button
 * to forget.
 */
function MyNotes({ callID, notes }: { callID: string; notes: string }) {
  const [value, setValue] = React.useState(notes);
  const [dirty, setDirty] = React.useState(false);

  const save = React.useCallback(
    async (text: string) => {
      await bridge("meetings.saveUserNotes", { callID, notes: text });
      setDirty(false);
    },
    [callID],
  );

  React.useEffect(() => {
    if (!dirty) return;
    const t = window.setTimeout(() => void save(value), 700);
    return () => window.clearTimeout(t);
  }, [value, dirty, save]);

  return (
    <>
      <div className="flex items-center justify-between">
        <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">My notes</p>
        {dirty ? <span className="text-[11px] text-muted-foreground">Saving…</span> : null}
      </div>
      <textarea
        value={value}
        onChange={(e) => {
          setValue(e.target.value);
          setDirty(true);
        }}
        onBlur={() => {
          if (dirty) void save(value);
        }}
        placeholder="Anything you jotted down — before, during or after the call."
        className="min-h-80 w-full resize-none rounded-lg border border-border bg-card p-3 text-[13.5px] leading-relaxed outline-none focus:border-primary/50"
      />
    </>
  );
}

// MARK: Transcript row — memoized and paint-deferred off-screen so a long
// call scrolls smoothly without a virtualization dependency.

const TranscriptRow = React.memo(function TranscriptRow({
  startedAtISO,
  t0,
  speakerLabel,
  colorClass,
  text,
}: {
  startedAtISO: string;
  t0: number;
  speakerLabel: string;
  colorClass: string;
  text: string;
}) {
  const time = new Date(new Date(startedAtISO).getTime() + t0 * 1000).toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
  });
  return (
    <div
      className="flex items-start gap-2 py-1"
      style={{ contentVisibility: "auto", containIntrinsicSize: "0 24px" } as React.CSSProperties}
    >
      <span className="w-[76px] shrink-0 font-mono text-[11px] text-muted-foreground">{time}</span>
      <span className={cn("w-20 shrink-0 text-[11px] font-semibold", colorClass)}>{speakerLabel}</span>
      <span className="min-w-0 flex-1 text-[12px] leading-relaxed" data-selectable>
        {text}
      </span>
    </div>
  );
});

// MARK: Detail pane

export function MeetingDetailPane({ callID, onDeleted }: { callID: string; onDeleted: () => void }) {
  const [detail, setDetail] = React.useState<MeetingDetailData | null>(null);
  const [pane, setPane] = React.useState<Pane>("summary");
  const [message, setMessage] = React.useState<string | null>(null);
  const [confirmingDelete, setConfirmingDelete] = React.useState(false);
  const [deleting, setDeleting] = React.useState(false);
  const [thread, setThread] = React.useState<ChatItem[]>([]);
  const [asking, setAsking] = React.useState(false);

  /** A follow-up question about this call, answered from its own transcript. */
  async function askQuestion(question: string) {
    const history = historyOf(thread);
    setThread((t) => [...t, { role: "user", content: question }]);
    setAsking(true);
    // The answer is appended to a placeholder turn as it is written; the
    // bridge call still resolves with the whole thing, which replaces it.
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
      const res = await bridge("meetings.ask", { callID, question, history, streamID: stream.id });
      setThread((t) => {
        const done: ChatItem = { role: "assistant", content: res.answer };
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

  const load = React.useCallback(async () => {
    const d = await bridge("meetings.detail", { callID });
    setDetail(d);
  }, [callID]);

  React.useEffect(() => {
    void load();
  }, [load]);

  React.useEffect(() => {
    if (!message) return;
    const t = window.setTimeout(() => setMessage(null), 4000);
    return () => window.clearTimeout(t);
  }, [message]);

  if (!detail) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
        <Loader2 className="mr-2 size-4 animate-spin" /> Loading…
      </div>
    );
  }

  const { call } = detail;
  const title = displayTitle(call);
  const resolvedNotes = detail.liveNotes ?? call.notes;

  const headerMeta = [formatDateTime(call.startedAt)];
  if (call.endedAt) headerMeta.push(meetingDuration(call.startedAt, call.endedAt));
  if (call.app) headerMeta.push(call.app);
  if (detail.speakers.length > 0) {
    headerMeta.push(`${detail.speakers.length} speaker${detail.speakers.length === 1 ? "" : "s"}`);
  }

  async function confirmDelete() {
    setDeleting(true);
    try {
      await bridge("meetings.delete", { callID });
      onDeleted();
    } finally {
      setDeleting(false);
      setConfirmingDelete(false);
    }
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex flex-col gap-2 border-b border-border px-6 py-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <h1 className="truncate text-[17px] font-semibold tracking-tight">{title}</h1>
            <p className="mt-0.5 text-xs text-muted-foreground">{headerMeta.join(" · ")}</p>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {message ? <span className="text-xs text-muted-foreground">{message}</span> : null}
            <InlineMenu
              trigger={(toggle) => (
                <Button variant="ghost" size="icon" onClick={toggle} aria-label="Meeting actions">
                  <MoreHorizontal className="size-4" />
                </Button>
              )}
            >
              {(close) => (
                <>
                  <MenuItem
                    disabled={detail.segments.length === 0}
                    onClick={() => {
                      void bridge("meetings.exportMarkdown", { callID }).then((r) => {
                        if (r.message) setMessage(r.message);
                      });
                      close();
                    }}
                  >
                    <Download className="size-3.5" /> Export as Markdown…
                  </MenuItem>
                  <MenuItem
                    disabled={detail.segments.length === 0}
                    onClick={() => {
                      void bridge("meetings.copyTranscript", { callID }).then((r) => setMessage(r.message));
                      close();
                    }}
                  >
                    <ClipboardCopy className="size-3.5" /> Copy transcript
                  </MenuItem>
                  <div className="my-1 h-px bg-border" />
                  <MenuItem
                    destructive
                    onClick={() => {
                      setConfirmingDelete(true);
                      close();
                    }}
                  >
                    <Trash2 className="size-3.5" /> Delete meeting…
                  </MenuItem>
                </>
              )}
            </InlineMenu>
          </div>
        </div>

        {detail.speakers.length > 0 ? (
          <div className="flex flex-wrap gap-1.5">
            {detail.speakers.map((s) => (
              <SpeakerChip
                key={s.id}
                profile={s}
                others={detail.allSpeakers.filter((o) => o.id !== s.id)}
                onRename={(name) => void bridge("meetings.renameSpeaker", { speakerID: s.id, name }).then(load)}
                onMerge={(targetID) => void bridge("meetings.mergeSpeaker", { sourceID: s.id, targetID }).then(load)}
                onDetach={() => void bridge("meetings.detachSpeaker", { callID, speakerID: s.id }).then(load)}
              />
            ))}
          </div>
        ) : null}

        <div className="inline-flex w-fit rounded-md border border-border p-0.5">
          {(
            [
              ["summary", "Summary"],
              ["notes", "My notes"],
              ["actions", "Actions"],
              ["transcript", "Transcript"],
            ] as [Pane, string][]
          ).map(([id, label]) => (
            <button
              key={id}
              onClick={() => setPane(id)}
              className={cn(
                "rounded px-3 py-1 text-[13px] transition-colors",
                pane === id ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground",
              )}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {pane === "summary" ? (
          <div className="mx-auto flex max-w-2xl flex-col gap-4 px-6 py-6">
            {resolvedNotes ? (
              <Markdown markdown={resolvedNotes} />
            ) : detail.isConsolidating ? (
              <div className="flex items-center gap-2 text-muted-foreground">
                <Loader2 className="size-3.5 animate-spin" />
                <span className="text-[13px]">Writing meeting notes…</span>
              </div>
            ) : call.summary ? (
              <div className="flex flex-col gap-1.5">
                <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
                  What came out of it
                </p>
                {digestBullets(call.summary).map((item, i) => (
                  <div key={i} className="flex items-start gap-2">
                    <span className="text-sm text-primary">•</span>
                    <p className="flex-1 text-[13.5px] leading-relaxed">{item}</p>
                  </div>
                ))}
              </div>
            ) : (
              <EmptyState
                title="No notes for this meeting"
                description="Notes are written when a call ends with a transcript."
              />
            )}

          </div>
        ) : null}

        {pane === "notes" ? (
          <div className="mx-auto flex max-w-2xl flex-col gap-2 px-6 py-6">
            <MyNotes callID={callID} notes={call.userNotes ?? ""} />
          </div>
        ) : null}

        {pane === "actions" ? (
          <div className="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-6">
            {detail.decisions.length === 0 && detail.followUps.length === 0 ? (
              <EmptyState
                icon={ListChecks}
                title="No actions from this meeting"
                description="Action items and follow-ups detected on a call show up here."
              />
            ) : null}
            {detail.decisions.length > 0 ? (
              <div className="flex flex-col gap-1.5">
                <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
                  Action items
                </p>
                {detail.decisions.map((d) => (
                  <DecisionRow key={d.id} decision={d} callID={callID} onChanged={load} />
                ))}
              </div>
            ) : null}
            {detail.followUps.length > 0 ? (
              <div className="flex flex-col gap-1.5">
                <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
                  Follow-ups
                </p>
                {detail.followUps.map((f) => (
                  <FollowUpRow key={f.id} followUp={f} callID={callID} onChanged={load} />
                ))}
              </div>
            ) : null}
          </div>
        ) : null}

        {pane === "transcript" ? (
          detail.segments.length === 0 ? (
            <EmptyState title="No transcript" description="No transcript segments were saved for this call." />
          ) : (
            <div className="mx-auto max-w-3xl px-6 py-6">
              {detail.segments.map((s) => (
                <TranscriptRow
                  key={s.id}
                  startedAtISO={call.startedAt}
                  t0={s.t0}
                  speakerLabel={s.source === "mic" ? "You" : s.speaker ?? "Others"}
                  colorClass={segmentColorClass(s)}
                  text={s.text}
                />
              ))}
            </div>
          )
        ) : null}
      </div>

      {/* Asking sits outside the scrolling panes so it stays reachable from
          the summary, the notes and halfway down a long transcript alike —
          the question is usually about the call, not about the tab. */}
      <div className="shrink-0 border-t border-border bg-background/80 px-6 py-3 backdrop-blur">
        <div className="mx-auto flex max-w-2xl flex-col gap-3">
          {thread.length > 0 || asking ? (
            <div className="max-h-64 overflow-y-auto pr-1">
              <ChatThread thread={thread} busy={asking} />
            </div>
          ) : null}
          <AskBar
            placeholder="Ask anything about this meeting"
            busy={asking}
            onSubmit={(q) => void askQuestion(q)}
            onClear={thread.length > 0 ? () => setThread([]) : undefined}
          />
        </div>
      </div>

      <Dialog open={confirmingDelete} onOpenChange={setConfirmingDelete}>
        <DialogContent>
          <DialogTitle>Delete “{title}”?</DialogTitle>
          <DialogDescription>
            The transcript, notes, and detected actions are removed. This can't be undone.
          </DialogDescription>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmingDelete(false)}>
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
