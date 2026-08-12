import * as React from "react";
import { bridge } from "@/lib/bridge";
import { EmptyState, Toolbar, useLive } from "@/components/live";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import type { HomeEvent } from "@/lib/types/home";
import { AudioLines, Calendar, CalendarPlus, ChevronRight, Hand, Zap } from "lucide-react";

/**
 * Home: the week ahead ("Coming up", Granola-style) plus live capture state.
 * Meetings come from the connected Google Calendar; joining a call still
 * works without any calendar — mic-ownership detection starts the notes.
 *
 * Ports Sources/OpenAvatar/UI/HomeView.swift (HomeTab) 1:1.
 */
export function HomePage() {
  const { data } = useLive("home.snapshot", {}, { topics: ["state"] });

  // Matches the native view's .onAppear — kick a best-effort calendar refresh
  // once per visit; live pushes on isListening/upcomingEvents keep it fresh
  // from there (WebEventBus fires "state" on any AppState change).
  React.useEffect(() => {
    void bridge("home.refresh");
  }, []);

  return (
    <div className="flex flex-col">
      <Toolbar title="Coming up" />
      {!data ? (
        <div className="px-8 py-16 text-center text-sm text-muted-foreground">Loading…</div>
      ) : (
        <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-8 py-6">
          <StatusCard isListening={data.isListening} autoStartOnCall={data.autoStartOnCall} />

          {!data.calendarEnabled || data.events.length === 0 ? (
            <EmptyState
              icon={data.calendarEnabled ? Calendar : CalendarPlus}
              title={data.calendarEnabled ? "Nothing scheduled" : "No calendar connected"}
              description={
                data.calendarEnabled
                  ? "No meetings in the next 7 days on your selected calendar."
                  : "Connect Google Calendar under Integrations to see your upcoming meetings here. Call detection and transcription work without it."
              }
            />
          ) : (
            <div className="flex flex-col gap-6">
              {groupByDay(data.events).map((group) => (
                <DaySection key={group.key} day={group.day} events={group.events} isListening={data.isListening} />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function StatusCard({ isListening, autoStartOnCall }: { isListening: boolean; autoStartOnCall: boolean }) {
  const icon = isListening ? (
    <AudioLines className="size-4" />
  ) : autoStartOnCall ? (
    <Zap className="size-4" />
  ) : (
    <Hand className="size-4" />
  );
  const tone = isListening
    ? "bg-success/12 text-success"
    : autoStartOnCall
      ? "bg-primary/12 text-primary"
      : "bg-secondary text-muted-foreground";
  const text = isListening
    ? "Transcribing now — notes and action items are being taken."
    : autoStartOnCall
      ? "When you join a call, transcription starts by itself — no clicks needed."
      : "Auto-start is off — start capture from the menu bar when a call begins (or turn it on in General).";

  return (
    <div className="flex items-center gap-3 rounded-xl border border-border bg-card p-3">
      <div className={cn("grid size-8 shrink-0 place-items-center rounded-lg", tone)}>{icon}</div>
      <p className={cn("flex-1 text-[13px]", !isListening && "text-muted-foreground")}>{text}</p>
      {isListening && (
        <Button size="sm" variant="outline" onClick={() => void bridge("home.stopListening")}>
          Stop
        </Button>
      )}
    </div>
  );
}

interface DayGroup {
  key: string;
  day: Date;
  events: HomeEvent[];
}

/** Groups by local calendar day and sorts, same as the native `days` property. */
function groupByDay(events: HomeEvent[]): DayGroup[] {
  const groups = new Map<string, DayGroup>();
  for (const event of events) {
    if (!event.start) continue;
    const d = new Date(event.start);
    const key = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
    let group = groups.get(key);
    if (!group) {
      group = { key, day: new Date(d.getFullYear(), d.getMonth(), d.getDate()), events: [] };
      groups.set(key, group);
    }
    group.events.push(event);
  }
  return [...groups.values()]
    .sort((a, b) => a.day.getTime() - b.day.getTime())
    .map((g) => ({
      ...g,
      events: [...g.events].sort((a, b) => new Date(a.start!).getTime() - new Date(b.start!).getTime()),
    }));
}

function isToday(day: Date): boolean {
  const now = new Date();
  return (
    day.getFullYear() === now.getFullYear() && day.getMonth() === now.getMonth() && day.getDate() === now.getDate()
  );
}

function DaySection({ day, events, isListening }: { day: Date; events: HomeEvent[]; isListening: boolean }) {
  return (
    <div className="flex items-start gap-4">
      <div className="flex w-11 shrink-0 flex-col items-center pt-1.5">
        <span className={cn("text-[22px] font-semibold", isToday(day) ? "text-primary" : "text-foreground")}>
          {day.toLocaleDateString(undefined, { day: "numeric" })}
        </span>
        <span className="text-[11px] text-muted-foreground">
          {day.toLocaleDateString(undefined, { weekday: "short" })}
        </span>
      </div>
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        {events.map((event) => (
          <EventRow key={event.id} event={event} isListening={isListening} />
        ))}
      </div>
    </div>
  );
}

function timeRange(start: string, end: string | null): string {
  const opts: Intl.DateTimeFormatOptions = { hour: "numeric", minute: "2-digit" };
  const startStr = new Date(start).toLocaleTimeString(undefined, opts);
  return end ? `${startStr} – ${new Date(end).toLocaleTimeString(undefined, opts)}` : startStr;
}

/**
 * The whole row opens the meeting's notes page — pre-write notes there; they
 * carry into the call once it starts. A plain div (not <button>) because
 * "Start notes" is its own button and buttons can't nest.
 */
function EventRow({ event, isListening }: { event: HomeEvent; isListening: boolean }) {
  const meta = [event.start ? timeRange(event.start, event.end) : null, event.participantSummary]
    .filter((p): p is string => Boolean(p))
    .join("  ·  ");
  const open = () => void bridge("home.openEventNotes", { eventID: event.id });

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={open}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          open();
        }
      }}
      title="Open this meeting's notes — write yours before the call starts"
      className="flex cursor-pointer items-center gap-3 rounded-xl border border-border bg-card p-3 transition-colors hover:bg-accent/40"
    >
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <div className="flex min-w-0 items-center gap-1.5">
          <span className="truncate text-[13px] font-medium">{event.title}</span>
          {event.isNow && <Badge variant="success">Now</Badge>}
          {event.conferenceService && <Badge variant="secondary">{event.conferenceService}</Badge>}
        </div>
        {meta && <p className="truncate text-xs text-muted-foreground">{meta}</p>}
      </div>
      {event.isNow && !isListening && (
        <Button
          size="sm"
          onClick={(e) => {
            e.stopPropagation();
            void bridge("home.startListening");
          }}
        >
          Start notes
        </Button>
      )}
      <ChevronRight className="size-4 shrink-0 text-muted-foreground/40" />
    </div>
  );
}
