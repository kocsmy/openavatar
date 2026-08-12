import * as React from "react";
import { bridge } from "@/lib/bridge";
import { useLive } from "@/components/live";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import type { CallAttendee, CallSpeaker } from "@/lib/types/call";
import { AudioWaveform, Copy, MessageSquareText, Pencil, UserPlus } from "lucide-react";

/**
 * Stable, distinct color per voice fingerprint — same djb2-ish hash as
 * TranscriptFormatter.color(forSpeakerID:), so a given voice reads the same
 * color every render without the server needing to assign one.
 */
const PALETTE = [
  { text: "text-blue-600 dark:text-blue-400", dot: "bg-blue-500" },
  { text: "text-emerald-600 dark:text-emerald-400", dot: "bg-emerald-500" },
  { text: "text-orange-600 dark:text-orange-400", dot: "bg-orange-500" },
  { text: "text-purple-600 dark:text-purple-400", dot: "bg-purple-500" },
  { text: "text-pink-600 dark:text-pink-400", dot: "bg-pink-500" },
  { text: "text-teal-600 dark:text-teal-400", dot: "bg-teal-500" },
  { text: "text-indigo-600 dark:text-indigo-400", dot: "bg-indigo-500" },
  { text: "text-amber-700 dark:text-amber-500", dot: "bg-amber-600" },
];

function paletteFor(id: string) {
  let hash = 5381;
  for (let i = 0; i < id.length; i++) hash = (Math.imul(hash, 33) ^ id.charCodeAt(i)) >>> 0;
  return PALETTE[hash % PALETTE.length];
}

function clock(t0: number): string {
  const m = Math.floor(t0 / 60);
  const s = Math.floor(t0 % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

/**
 * Live, speaker-labeled transcript of the current call — port of
 * LiveTranscriptView. Auto-scrolls to the newest line, but only while the
 * user hasn't scrolled up to read back; once they do, new lines stop pulling
 * the view down until they return to the bottom themselves.
 */
export function TranscriptPane({ isListening }: { isListening: boolean }) {
  const { data } = useLive("call.transcript", {}, { topics: ["state", "transcript"] });
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const atBottomRef = React.useRef(true);
  const segments = data?.segments ?? [];

  const onScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    atBottomRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
  };

  React.useEffect(() => {
    const el = scrollRef.current;
    if (!el || !atBottomRef.current) return;
    el.scrollTop = el.scrollHeight;
  }, [segments.length]);

  if (!data) return null;

  return (
    <div className="flex h-full flex-col gap-2 overflow-hidden px-6 py-3">
      <SpeakerRoster eventTitle={data.eventTitle} speakers={data.speakers} attendees={data.attendees} />

      {segments.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 px-4 text-center">
          {isListening ? (
            <AudioWaveform className="size-6 text-muted-foreground/40" />
          ) : (
            <MessageSquareText className="size-6 text-muted-foreground/40" />
          )}
          <p className="max-w-xs text-xs leading-relaxed text-muted-foreground">
            {isListening
              ? "Listening — the transcript appears here as people speak…"
              : "Start listening to see the live transcript. Past calls live under Meetings."}
          </p>
        </div>
      ) : (
        <>
          <div ref={scrollRef} onScroll={onScroll} className="min-h-0 flex-1 overflow-y-auto">
            <div className="flex flex-col gap-1.5 pb-1" data-selectable>
              {segments.map((seg) => {
                const palette = seg.source === "mic" ? null : paletteFor(seg.speakerId ?? seg.speakerLabel);
                return (
                  <div key={seg.id} className="flex items-start gap-1.5 text-xs">
                    <span className="mt-px shrink-0 font-mono text-[10px] text-muted-foreground/60">
                      {clock(seg.t0)}
                    </span>
                    <span
                      className={cn(
                        "w-16 shrink-0 truncate font-semibold",
                        seg.source === "mic" ? "text-primary" : palette?.text,
                      )}
                    >
                      {seg.speakerLabel}
                    </span>
                    <span className="min-w-0 flex-1 leading-relaxed">{seg.text}</span>
                  </div>
                );
              })}
            </div>
          </div>
          <div className="flex items-center justify-between border-t border-border pt-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => void bridge("call.copyTranscript", {})}
            >
              <Copy /> Copy transcript
            </Button>
            <span className="text-[11px] text-muted-foreground/60">
              {segments.length} segments — saved automatically
            </span>
          </div>
        </>
      )}
    </div>
  );
}

/**
 * The distinct voices heard this call with inline renaming, plus calendar
 * attendees as one-tap name suggestions — port of SpeakerRosterView. A name
 * assigned here sticks to the voice fingerprint: it relabels the whole
 * transcript and carries to future calls.
 */
function SpeakerRoster({
  eventTitle,
  speakers,
  attendees,
}: {
  eventTitle: string | null;
  speakers: CallSpeaker[];
  attendees: CallAttendee[];
}) {
  if (speakers.length === 0 && !eventTitle) return null;
  return (
    <div className="flex flex-col gap-1 rounded-md bg-muted/50 p-2">
      {eventTitle ? <p className="truncate text-[11px] text-muted-foreground">{eventTitle}</p> : null}
      {speakers.map((speaker) => (
        <SpeakerRosterRow key={speaker.id} speaker={speaker} attendees={attendees} />
      ))}
      {speakers.length === 0 && attendees.length > 0 ? (
        <p className="truncate text-[11px] text-muted-foreground/70">
          Attendees: {attendees.map((a) => a.name).join(", ")}
        </p>
      ) : null}
    </div>
  );
}

function SpeakerRosterRow({ speaker, attendees }: { speaker: CallSpeaker; attendees: CallAttendee[] }) {
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState("");
  const [menuOpen, setMenuOpen] = React.useState(false);
  const menuRef = React.useRef<HTMLDivElement>(null);
  const dot = paletteFor(speaker.id).dot;

  React.useEffect(() => {
    if (!menuOpen) return;
    const onDown = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setMenuOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [menuOpen]);

  const commit = (name: string) => {
    void bridge("call.renameSpeaker", { id: speaker.id, name });
    setEditing(false);
    setMenuOpen(false);
  };

  return (
    <div className="flex items-center gap-1.5 text-xs">
      <span className={cn("size-2 shrink-0 rounded-full", dot)} />
      {editing ? (
        <>
          <Input
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") commit(draft);
              if (e.key === "Escape") setEditing(false);
            }}
            className="h-6 max-w-[150px] px-1.5 text-xs"
          />
          <Button size="sm" variant="ghost" className="h-6 px-1.5" onClick={() => commit(draft)}>
            Save
          </Button>
          <Button size="sm" variant="ghost" className="h-6 px-1.5" onClick={() => setEditing(false)}>
            Cancel
          </Button>
        </>
      ) : (
        <>
          <span className="font-medium">{speaker.label}</span>
          <span className="text-muted-foreground/60">({speaker.segmentCount})</span>
          <div className="flex-1" />
          {attendees.length > 0 ? (
            <div ref={menuRef} className="relative">
              <button
                type="button"
                aria-label="Assign a calendar attendee's name"
                title="Assign a calendar attendee's name"
                onClick={() => setMenuOpen((v) => !v)}
                className="rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground"
              >
                <UserPlus className="size-3.5" />
              </button>
              {menuOpen ? (
                <div className="absolute right-0 top-full z-10 mt-1 min-w-32 rounded-md border border-border bg-popover p-1 shadow-md">
                  {attendees.map((a) => (
                    <button
                      key={a.id}
                      type="button"
                      onClick={() => commit(a.name)}
                      className="block w-full rounded-sm px-2 py-1 text-left text-xs hover:bg-accent"
                    >
                      {a.name}
                    </button>
                  ))}
                </div>
              ) : null}
            </div>
          ) : null}
          <button
            type="button"
            aria-label="Rename this voice"
            title="Rename this voice"
            onClick={() => {
              setDraft(speaker.label.startsWith("Speaker ") ? "" : speaker.label);
              setEditing(true);
            }}
            className="rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground"
          >
            <Pencil className="size-3.5" />
          </button>
        </>
      )}
    </div>
  );
}
