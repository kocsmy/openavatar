import * as React from "react";
import { bridge } from "@/lib/bridge";
import { cn } from "@/lib/utils";
import { HomePage } from "@/pages/main/Home";
import { MeetingsPage } from "@/pages/main/Meetings";
import { FollowUpsPage } from "@/pages/main/FollowUps";
import { MetricsPage } from "@/pages/main/Metrics";
import { AudioWaveform, BarChart3, BellRing, CalendarDays, House, Settings } from "lucide-react";

/*
 * The main window: content up top (Home, Meetings), configuration in its own
 * window — the same shape the native sidebar had, so nothing about the app's
 * navigation had to be relearned when the rendering changed.
 */
const SECTIONS = [
  { id: "home", label: "Home", icon: House, page: HomePage, group: "" },
  { id: "meetings", label: "Meetings", icon: CalendarDays, page: MeetingsPage, group: "Library" },
  { id: "followups", label: "Follow-ups", icon: BellRing, page: FollowUpsPage, group: "Library" },
  { id: "metrics", label: "Metrics", icon: BarChart3, page: MetricsPage, group: "Library" },
] as const;

type SectionID = (typeof SECTIONS)[number]["id"];

const sectionFromHash = (): SectionID | null => {
  const id = window.location.hash.replace("#", "");
  return SECTIONS.some((s) => s.id === id) ? (id as SectionID) : null;
};

export default function MainWindow() {
  const [section, setSection] = React.useState<SectionID>(() => sectionFromHash() ?? "home");

  React.useEffect(() => {
    const onHash = () => {
      const id = sectionFromHash();
      if (id) setSection(id);
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const Active = SECTIONS.find((s) => s.id === section)!.page;

  return (
    <div className="flex h-screen bg-background text-foreground">
      <nav className="flex w-48 shrink-0 flex-col gap-0.5 border-r border-border bg-sidebar px-2.5 py-3">
        <div className="flex items-center gap-2 px-2 pb-3 pt-1">
          <div className="grid size-6 place-items-center rounded-md bg-primary/12 text-primary">
            <AudioWaveform className="size-3.5" />
          </div>
          <span className="text-[13px] font-semibold">OpenAvatar</span>
        </div>

        {SECTIONS.map((s, i) => (
          <React.Fragment key={s.id}>
            {s.group && SECTIONS[i - 1]?.group !== s.group ? (
              <div className="px-2 pb-1 pt-3 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
                {s.group}
              </div>
            ) : null}
            <button
              onClick={() => {
                setSection(s.id);
                window.location.hash = s.id;
              }}
              className={cn(
                "flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] transition-colors",
                section === s.id
                  ? "bg-primary/10 font-medium text-primary"
                  : "text-foreground/80 hover:bg-accent/60",
              )}
            >
              <s.icon
                className={cn("size-4", section === s.id ? "text-primary" : "text-muted-foreground")}
              />
              {s.label}
            </button>
          </React.Fragment>
        ))}

        <div className="flex-1" />
        <button
          onClick={() => void bridge("window.open", { window: "settings" })}
          className="flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-[13px] text-foreground/80 transition-colors hover:bg-accent/60"
        >
          <Settings className="size-4 text-muted-foreground" />
          Settings
        </button>
      </nav>

      <main className="min-w-0 flex-1 overflow-y-auto">
        <Active />
      </main>
    </div>
  );
}
