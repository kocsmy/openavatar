import { Button } from "@/components/ui/button";
import { CircleX, Copy, PhoneCall, TriangleAlert } from "lucide-react";

/** Mirrors MenuBarView.callSuggestionBanner. */
export function CallSuggestionBanner({ appName, onStart }: { appName: string; onStart: () => void }) {
  return (
    <div className="flex items-center gap-2.5 rounded-lg bg-primary/9 p-2.5">
      <div className="grid size-8 shrink-0 place-items-center rounded-full bg-primary/15 text-primary">
        <PhoneCall className="size-4" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="text-[12.5px] font-semibold leading-tight">{appName} looks active</p>
        <p className="text-[11.5px] text-muted-foreground">Start listening for this call?</p>
      </div>
      <Button size="sm" onClick={onStart}>
        Start
      </Button>
    </div>
  );
}

/** Mirrors MenuBarView.errorCard. Copies via the web Clipboard API — the same
 * result as the native NSPasteboard copy, from inside the page. */
export function ErrorCard({
  message,
  count,
  onClear,
}: {
  message: string;
  count: number;
  onClear: () => void;
}) {
  const copy = () => {
    void navigator.clipboard?.writeText(message);
  };
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-2">
        <TriangleAlert className="size-3.5 shrink-0 text-warning" />
        <span className="text-[12.5px] font-semibold text-warning">Something went wrong</span>
        <div className="flex-1" />
        <button
          onClick={copy}
          title="Copy full error"
          className="rounded p-1 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
        >
          <Copy className="size-3.5" />
        </button>
        <button
          onClick={onClear}
          title="Dismiss"
          className="rounded p-1 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
        >
          <CircleX className="size-3.5" />
        </button>
      </div>
      <div
        data-selectable
        className="max-h-32 overflow-y-auto whitespace-pre-wrap break-words rounded-md bg-warning/8 p-1.5 font-mono text-[11px] leading-relaxed text-warning"
      >
        {message}
      </div>
      {count > 1 ? (
        <p className="text-[11px] text-muted-foreground/70">
          {count} errors this session — full log in Settings → Data
        </p>
      ) : null}
    </div>
  );
}
