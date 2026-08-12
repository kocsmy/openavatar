import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { AudioLines, AudioWaveform, Loader2, Square } from "lucide-react";

/** Mirrors MenuBarView.header. */
export function Header({
  assistantName,
  isListening,
  systemAudioActive,
  isPlanning,
  isConsolidating,
  onToggle,
}: {
  assistantName: string;
  isListening: boolean;
  systemAudioActive: boolean;
  isPlanning: boolean;
  isConsolidating: boolean;
  onToggle: () => void;
}) {
  const statusText = !isListening ? "Idle" : systemAudioActive ? "Listening · mic + call audio" : "Listening · mic";
  return (
    <div className="flex items-center gap-2.5 px-3.5 pb-2.5 pt-3">
      <div
        className={cn(
          "grid size-9 shrink-0 place-items-center rounded-full",
          isListening ? "bg-destructive/12 text-destructive" : "bg-secondary text-muted-foreground",
        )}
      >
        <AudioLines className="size-4.5" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="truncate text-[14px] font-semibold leading-tight">{assistantName}</p>
        <div className="flex items-center gap-1.5">
          <p className="text-[11.5px] text-muted-foreground">{statusText}</p>
          {isPlanning ? <Loader2 className="size-3 animate-spin text-muted-foreground" /> : null}
          {isConsolidating ? <span className="text-[10.5px] text-muted-foreground/70">· saving</span> : null}
        </div>
      </div>
      <Button
        size="lg"
        variant={isListening ? "destructive" : "default"}
        onClick={onToggle}
        className="min-w-17 shrink-0"
      >
        {isListening ? <Square className="size-3.5 fill-current" /> : <AudioWaveform className="size-3.5" />}
        {isListening ? "Stop" : "Listen"}
      </Button>
    </div>
  );
}
