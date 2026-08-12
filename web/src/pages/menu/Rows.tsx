import { cn } from "@/lib/utils";
import type { AssistantMode } from "@/lib/types";
import { AppWindow, NotebookText, Power, Settings } from "lucide-react";
import { GhostRow } from "./common";

/** Mirrors MenuBarView.menuRows: Granola-style quick rows between content and the mode footer. */
export function MenuRows({
  version,
  onOpenMain,
  onOpenCall,
  onCheckUpdates,
}: {
  version: string;
  onOpenMain: () => void;
  onOpenCall: () => void;
  onCheckUpdates: () => void;
}) {
  return (
    <div className="flex flex-col gap-0.5 px-3.5 py-2">
      <GhostRow onClick={onOpenMain}>
        <AppWindow className="mr-2 size-4 shrink-0 text-muted-foreground" />
        <span className="text-[13px]">Open OpenAvatar</span>
      </GhostRow>
      <GhostRow onClick={onOpenCall}>
        <NotebookText className="mr-2 size-4 shrink-0 text-muted-foreground" />
        <span className="text-[13px]">Call notes &amp; transcript</span>
      </GhostRow>
      <div className="flex items-center gap-2 px-2 pt-1">
        <span className="text-[10.5px] text-muted-foreground/60">v{version}</span>
        <div className="flex-1" />
        <button onClick={onCheckUpdates} className="text-[11.5px] text-primary hover:underline">
          Check for updates
        </button>
      </div>
    </div>
  );
}

/** Mirrors MenuBarView.footer: mode picker, settings, quit. */
export function Footer({
  assistantName,
  mode,
  onModeChange,
  onOpenSettings,
  onQuit,
}: {
  assistantName: string;
  mode: AssistantMode;
  onModeChange: (mode: AssistantMode) => void;
  onOpenSettings: () => void;
  onQuit: () => void;
}) {
  return (
    <div className="flex items-center gap-2.5 px-3.5 py-2.5">
      <span className="text-[12px] text-muted-foreground">Mode</span>
      <ModeToggle mode={mode} onChange={onModeChange} assistantName={assistantName} />
      <div className="flex-1" />
      <button
        onClick={onOpenSettings}
        title="Settings"
        className="rounded p-1.5 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
      >
        <Settings className="size-4" />
      </button>
      <button
        onClick={onQuit}
        title={`Quit ${assistantName}`}
        className="rounded p-1.5 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
      >
        <Power className="size-4" />
      </button>
    </div>
  );
}

const MODES: AssistantMode[] = ["passive", "active"];

function ModeToggle({
  mode,
  onChange,
  assistantName,
}: {
  mode: AssistantMode;
  onChange: (mode: AssistantMode) => void;
  assistantName: string;
}) {
  return (
    <div
      title={`Passive: review after the call. Active: executes immediately when you address ${assistantName} by name.`}
      className="inline-flex rounded-md bg-secondary p-0.5"
    >
      {MODES.map((m) => (
        <button
          key={m}
          onClick={() => onChange(m)}
          className={cn(
            "rounded-[5px] px-2.5 py-1 text-[11.5px] font-medium capitalize transition-colors",
            mode === m ? "bg-card text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground",
          )}
        >
          {m}
        </button>
      ))}
    </div>
  );
}
