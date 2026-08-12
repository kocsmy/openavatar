import * as React from "react";
import { SettingsProvider } from "@/components/shared";
import { GeneralPage } from "@/pages/General";
import { TranscriptionPage } from "@/pages/Transcription";
import { ModelsPage } from "@/pages/Models";
import { IntegrationsPage } from "@/pages/Integrations";
import { TrustPage } from "@/pages/Trust";
import { MemoryPage } from "@/pages/Memory";
import { DataPage } from "@/pages/Data";
import { cn } from "@/lib/utils";
import {
  AudioWaveform,
  Brain,
  Database,
  Puzzle,
  Settings2,
  ShieldCheck,
  Sparkles,
} from "lucide-react";

const SECTIONS = [
  { id: "general", label: "General", icon: Settings2, page: GeneralPage },
  { id: "transcription", label: "Transcription", icon: AudioWaveform, page: TranscriptionPage },
  { id: "models", label: "Models", icon: Sparkles, page: ModelsPage },
  { id: "integrations", label: "Integrations", icon: Puzzle, page: IntegrationsPage },
  { id: "trust", label: "Trust", icon: ShieldCheck, page: TrustPage },
  { id: "memory", label: "Memory", icon: Brain, page: MemoryPage },
  { id: "data", label: "Data", icon: Database, page: DataPage },
] as const;

type SectionID = (typeof SECTIONS)[number]["id"];

export default function App() {
  const [section, setSection] = React.useState<SectionID>(() => {
    const fromHash = window.location.hash.replace("#", "");
    return SECTIONS.some((s) => s.id === fromHash) ? (fromHash as SectionID) : "general";
  });

  // The host (or a test) can deep-link a section by setting the hash.
  React.useEffect(() => {
    const onHash = () => {
      const id = window.location.hash.replace("#", "");
      if (SECTIONS.some((s) => s.id === id)) setSection(id as SectionID);
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const Active = SECTIONS.find((s) => s.id === section)!.page;

  return (
    <SettingsProvider>
      <div className="flex h-screen">
        <nav className="flex w-44 shrink-0 flex-col gap-0.5 border-r border-border bg-sidebar px-2.5 py-3">
          <div className="px-2 pb-2 pt-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground/70">
            Settings
          </div>
          {SECTIONS.map((s) => (
            <button
              key={s.id}
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
              <s.icon className={cn("size-4", section === s.id ? "text-primary" : "text-muted-foreground")} />
              {s.label}
            </button>
          ))}
        </nav>
        <main className="min-w-0 flex-1 overflow-y-auto">
          <Active />
        </main>
      </div>
    </SettingsProvider>
  );
}
