import * as React from "react";
import { bridge } from "@/lib/bridge";
import { useLive } from "@/components/live";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { MeetingDetailPane } from "@/pages/main/MeetingDetail";
import { NotesPane } from "@/pages/call/NotesPane";
import { TranscriptPane } from "@/pages/call/Transcript";
import type { CallPreviewEvent } from "@/lib/types/call";
import { AudioWaveform, Calendar as CalendarIcon, Check } from "lucide-react";

type Pane = "notes" | "transcript";

/**
 * The per-call window (Granola-style): pops up in the background when a call
 * starts. "My notes" is the user's own scratchpad, autosaved onto the call
 * record; "Transcript" is the live feed. Before a call, the same window shows
 * an upcoming meeting instead — its details plus a notes pad seeded from (and
 * carried into) the call once it starts.
 *
 * Port of CallNotesWindowView, including its post-call takeover: once the
 * call ends the window becomes the meeting detail, reusing the Meetings
 * surface's own pane so the review lives in one place.
 */
export default function CallSurface() {
  const { data } = useLive("call.state", {}, { topics: ["state"] });
  const [pane, setPane] = React.useState<Pane>("notes");

  if (!data) return null;

  // Native handed the whole window over to the meeting detail once a call
  // ended — that review is where the detected actions get approved, so it
  // stays one window rather than becoming a trip to another one.
  if (data.mode === "ended" && data.ended) {
    return (
      <MeetingDetailPane
        callID={data.ended.callID}
        onDeleted={() => void bridge("window.close", {})}
      />
    );
  }

  const isPreview = data.mode === "event";

  return (
    <div className="flex h-screen flex-col overflow-hidden">
      <div className="px-4 py-3">
        {isPreview && data.event ? (
          <EventHeader event={data.event} autoStartOnCall={data.autoStartOnCall} />
        ) : (
          <CallHeader isListening={data.isListening} assistantName={data.assistantName} />
        )}
      </div>
      <div className="border-b border-border" />

      {!isPreview ? (
        <div className="px-4 py-2.5">
          <PanePicker pane={pane} onChange={setPane} />
        </div>
      ) : null}

      <div className="min-h-0 flex-1">
        {isPreview || pane === "notes" ? (
          <NotesPane
            targetId={data.targetId}
            initialText={data.notes}
            placeholder={
              isPreview
                ? "Write your notes for this meeting ahead of time — saved automatically."
                : "Write your own notes for this call — saved automatically."
            }
          />
        ) : (
          <TranscriptPane isListening={data.isListening} />
        )}
      </div>
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
        <p className="text-[13px] font-semibold">{isListening ? "Transcribing this call" : "Call ended"}</p>
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
          <p className="truncate text-[13px] font-semibold">{event.title}</p>
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
    <div className="inline-flex rounded-md bg-muted p-0.5">
      {options.map((o) => (
        <button
          key={o.id}
          type="button"
          onClick={() => onChange(o.id)}
          className={cn(
            "rounded-[5px] px-3 py-1 text-xs font-medium transition-colors",
            pane === o.id ? "bg-card text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground",
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
