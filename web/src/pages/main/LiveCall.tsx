import * as React from "react";
import { bridge } from "@/lib/bridge";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { NotesPane } from "@/pages/call/NotesPane";
import { TranscriptPane } from "@/pages/call/Transcript";
import type { CallPreviewEvent, CallStateResult } from "@/lib/types/call";
import { AudioWaveform, Calendar as CalendarIcon, Check } from "lucide-react";

type Pane = "notes" | "transcript";

/**
 * The call as it happens, inside Meetings rather than in a window of its own.
 *
 * This used to be a separate "Call notes" window that popped up beside the
 * call and then handed itself over to the meeting page once the call ended —
 * two windows showing the same meeting at different points in its life. The
 * live call is just the newest entry in the library, so it belongs at the top
 * of the same list, and the handover is now simply the row ceasing to be live.
 *
 * Before a call, the same pane shows an upcoming meeting instead: its details
 * plus a notes pad that carries into the call once it starts.
 */
export function LiveCallPane({ state }: { state: CallStateResult }) {
  const [pane, setPane] = React.useState<Pane>("notes");
  const isPreview = state.mode === "event";

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex flex-col gap-3 border-b border-border px-6 py-4">
        {isPreview && state.event ? (
          <EventHeader event={state.event} autoStartOnCall={state.autoStartOnCall} />
        ) : (
          <CallHeader isListening={state.isListening} assistantName={state.assistantName} />
        )}
        {!isPreview ? <PanePicker pane={pane} onChange={setPane} /> : null}
      </div>

      <div className="min-h-0 flex-1">
        {isPreview || pane === "notes" ? (
          <NotesPane
            targetId={state.targetId}
            initialText={state.notes}
            placeholder={
              isPreview
                ? "Write your notes for this meeting ahead of time — saved automatically."
                : "Write your own notes for this call — saved automatically."
            }
          />
        ) : (
          <TranscriptPane isListening={state.isListening} />
        )}
      </div>
    </div>
  );
}

/** The list row for whatever is happening now — pinned above the history. */
export function LiveCallRow({
  state,
  selected,
  onSelect,
}: {
  state: CallStateResult;
  selected: boolean;
  onSelect: () => void;
}) {
  const isPreview = state.mode === "event";
  const title = isPreview ? (state.event?.title ?? "Upcoming meeting") : "Current call";
  const detail = isPreview
    ? (state.event?.participantSummary ?? "Write your notes before it starts")
    : state.isListening
      ? `${state.assistantName} is taking notes`
      : "Not listening yet";

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(e) => e.key === "Enter" && onSelect()}
      className={cn(
        "flex cursor-default items-center gap-2 rounded-md px-2.5 py-2 text-left transition-colors",
        selected ? "bg-primary/10" : "hover:bg-accent/60",
      )}
    >
      {state.isListening ? (
        <span className="relative flex size-2 shrink-0">
          <span className="absolute inline-flex size-full animate-ping rounded-full bg-destructive opacity-70" />
          <span className="relative inline-flex size-2 rounded-full bg-destructive" />
        </span>
      ) : (
        <CalendarIcon className="size-3.5 shrink-0 text-muted-foreground" />
      )}
      <div className="min-w-0 flex-1">
        <p className="truncate text-[13px] font-medium">{title}</p>
        <p className="truncate text-xs text-muted-foreground">{detail}</p>
      </div>
      {isPreview && state.event?.conferenceService ? (
        <Badge variant="outline" className="shrink-0">
          {state.event.conferenceService}
        </Badge>
      ) : null}
    </div>
  );
}

function IconPlate({
  icon: Icon,
  tone,
}: {
  icon: React.ComponentType<{ className?: string }>;
  tone: "brand" | "success" | "destructive";
}) {
  return (
    <div
      className={cn(
        "grid size-9 shrink-0 place-items-center rounded-full",
        tone === "brand" && "bg-primary/12 text-primary",
        tone === "success" && "bg-success/12 text-success",
        tone === "destructive" && "bg-destructive/12 text-destructive",
      )}
    >
      <Icon className="size-4" />
    </div>
  );
}

function CallHeader({ isListening, assistantName }: { isListening: boolean; assistantName: string }) {
  return (
    <div className="flex items-center gap-3">
      <IconPlate icon={isListening ? AudioWaveform : Check} tone={isListening ? "destructive" : "success"} />
      <div className="min-w-0 flex-1">
        <p className="text-[15px] font-semibold">{isListening ? "Transcribing this call" : "Call ended"}</p>
        <p className="text-xs text-muted-foreground">
          {isListening
            ? `${assistantName} is taking notes — write your own alongside.`
            : "Your notes are saved with the call and included in exports."}
        </p>
      </div>
      {isListening ? (
        <Button variant="destructive" size="sm" onClick={() => void bridge("call.stop", {})}>
          Stop
        </Button>
      ) : null}
    </div>
  );
}

function EventHeader({ event, autoStartOnCall }: { event: CallPreviewEvent; autoStartOnCall: boolean }) {
  const meta = [formatDateTime(event.start, event.end), event.participantSummary].filter(Boolean).join(" · ");
  return (
    <div className="flex items-start gap-3">
      <IconPlate icon={CalendarIcon} tone="brand" />
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <p className="truncate text-[15px] font-semibold">{event.title}</p>
          {event.conferenceService ? <Badge variant="outline">{event.conferenceService}</Badge> : null}
        </div>
        {meta ? <p className="text-xs text-muted-foreground">{meta}</p> : null}
        <p className="text-xs text-muted-foreground/70">
          {autoStartOnCall
            ? "Notes written here carry into the call — transcription starts by itself when you join."
            : "Notes written here carry into the call once you start listening."}
        </p>
      </div>
    </div>
  );
}

function PanePicker({ pane, onChange }: { pane: Pane; onChange: (p: Pane) => void }) {
  const options: { id: Pane; label: string }[] = [
    { id: "notes", label: "My notes" },
    { id: "transcript", label: "Transcript" },
  ];
  return (
    <div className="inline-flex w-fit rounded-md border border-border p-0.5">
      {options.map((o) => (
        <button
          key={o.id}
          type="button"
          onClick={() => onChange(o.id)}
          className={cn(
            "rounded px-3 py-1 text-[13px] transition-colors",
            pane === o.id ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

function formatDateTime(startIso: string | null, endIso: string | null): string {
  if (!startIso) return "";
  const start = new Date(startIso);
  if (Number.isNaN(start.getTime())) return "";
  let label = start.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
  if (endIso) {
    const end = new Date(endIso);
    if (!Number.isNaN(end.getTime())) {
      label += " – " + end.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    }
  }
  return label;
}
