import { formatTime } from "@/components/live";
import { Badge } from "@/components/ui/badge";
import type { MenuEvent } from "@/lib/types/menu";
import { ChevronRight } from "lucide-react";
import { GhostRow, SectionLabel } from "./common";

/** Mirrors MenuBarView.upcomingRow / upcomingSoon (already filtered server-side). */
export function UpcomingSection({
  events,
  onOpen,
}: {
  events: MenuEvent[];
  onOpen: (eventID: string) => void;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <SectionLabel>Coming up</SectionLabel>
      <div className="flex flex-col">
        {events.map((event) => (
          <UpcomingRow key={event.id} event={event} onOpen={() => onOpen(event.id)} />
        ))}
      </div>
    </div>
  );
}

function UpcomingRow({ event, onOpen }: { event: MenuEvent; onOpen: () => void }) {
  const isToday = event.startISO
    ? new Date(event.startISO).toDateString() === new Date().toDateString()
    : true;
  return (
    <GhostRow onClick={onOpen} title="Open this meeting's notes — write yours before the call starts">
      <div className="flex w-full items-center gap-2.5">
        <div className="w-14 shrink-0 leading-tight">
          {event.startISO ? (
            <>
              <div className="text-[12px] font-semibold tabular-nums">{formatTime(event.startISO)}</div>
              <div className="text-[10.5px] text-muted-foreground/70">{isToday ? "Today" : "Tomorrow"}</div>
            </>
          ) : null}
        </div>
        <div className="min-w-0 flex-1">
          <p className="truncate text-[13px]">{event.title}</p>
          {event.participantSummary ? (
            <p className="truncate text-[11px] text-muted-foreground/70">{event.participantSummary}</p>
          ) : null}
        </div>
        {event.conferenceService ? (
          <Badge variant="outline" className="shrink-0">
            {event.conferenceService}
          </Badge>
        ) : null}
        <ChevronRight className="size-3.5 shrink-0 text-muted-foreground/40" />
      </div>
    </GhostRow>
  );
}
