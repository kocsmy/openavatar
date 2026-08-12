import * as React from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { ArrowUp, Loader2, Sparkles, X } from "lucide-react";

/**
 * Asking questions about what was said. Shared by the meeting page (one call
 * in context) and the library search (the model picks which calls to read) —
 * same thread, same composer, so the two feel like one feature.
 */
export interface ChatItem {
  role: "user" | "assistant";
  content: string;
  /** Rendered as an error rather than an answer, and never sent as history. */
  failed?: boolean;
  /** Meetings this answer drew on. */
  callIDs?: string[];
}

/** The turns to send back as history — failures would only confuse the model. */
export function historyOf(thread: ChatItem[]): { role: "user" | "assistant"; content: string }[] {
  return thread.filter((t) => !t.failed).map(({ role, content }) => ({ role, content }));
}

export function ChatThread({
  thread,
  busy,
  renderCitations,
  className,
}: {
  thread: ChatItem[];
  busy?: boolean;
  /** Optional per-answer citation row (meeting chips). */
  renderCitations?: (callIDs: string[]) => React.ReactNode;
  className?: string;
}) {
  const endRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    endRef.current?.scrollIntoView({ block: "end", behavior: "smooth" });
  }, [thread.length, busy]);

  if (thread.length === 0 && !busy) return null;

  return (
    <div className={cn("flex flex-col gap-3", className)}>
      {thread.map((item, i) =>
        item.role === "user" ? (
          <div key={i} className="flex justify-end">
            <p className="max-w-[85%] rounded-2xl rounded-br-md bg-secondary px-3 py-1.5 text-[13px]" data-selectable>
              {item.content}
            </p>
          </div>
        ) : (
          <div key={i} className="flex flex-col gap-1.5">
            <div className="flex gap-2">
              <Sparkles
                className={cn("mt-0.5 size-3.5 shrink-0", item.failed ? "text-destructive" : "text-primary")}
              />
              <p
                className={cn(
                  "min-w-0 flex-1 whitespace-pre-wrap text-[13.5px] leading-relaxed",
                  item.failed && "text-destructive",
                )}
                data-selectable
              >
                {item.content}
              </p>
            </div>
            {item.callIDs?.length && renderCitations ? (
              <div className="flex flex-wrap gap-1.5 pl-5.5">{renderCitations(item.callIDs)}</div>
            ) : null}
          </div>
        ),
      )}
      {busy ? (
        <div className="flex items-center gap-2 text-muted-foreground">
          <Loader2 className="size-3.5 animate-spin" />
          <span className="text-[13px]">Reading the transcript…</span>
        </div>
      ) : null}
      <div ref={endRef} />
    </div>
  );
}

/**
 * The composer. Deliberately a single line that grows: a call question is
 * usually short ("what did we decide about pricing?"), and a tall empty box
 * at the bottom of every meeting would be in the way.
 */
export function AskBar({
  placeholder = "Ask anything",
  busy = false,
  autoFocus = false,
  onSubmit,
  onClear,
}: {
  placeholder?: string;
  busy?: boolean;
  autoFocus?: boolean;
  onSubmit: (question: string) => void;
  /** Shown as a dismiss button when a thread is open. */
  onClear?: () => void;
}) {
  const [value, setValue] = React.useState("");
  const areaRef = React.useRef<HTMLTextAreaElement>(null);

  function grow() {
    const el = areaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 140)}px`;
  }

  function send() {
    const question = value.trim();
    if (!question || busy) return;
    setValue("");
    requestAnimationFrame(grow);
    onSubmit(question);
  }

  return (
    <div className="flex items-end gap-2 rounded-2xl border border-border bg-card p-1.5 pl-3 shadow-sm focus-within:border-primary/50">
      <textarea
        ref={areaRef}
        rows={1}
        value={value}
        autoFocus={autoFocus}
        placeholder={placeholder}
        onChange={(e) => {
          setValue(e.target.value);
          grow();
        }}
        onKeyDown={(e) => {
          // Enter sends; Shift+Enter is a newline, the convention every chat
          // box uses and the one people's fingers already know.
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            send();
          }
        }}
        className="max-h-35 min-w-0 flex-1 resize-none bg-transparent py-1.5 text-[13px] outline-none placeholder:text-muted-foreground"
      />
      {onClear ? (
        <Button variant="ghost" size="icon" onClick={onClear} aria-label="Close" title="Clear this thread">
          <X className="size-3.5" />
        </Button>
      ) : null}
      <Button size="icon" disabled={!value.trim() || busy} onClick={send} aria-label="Ask">
        {busy ? <Loader2 className="size-3.5 animate-spin" /> : <ArrowUp className="size-3.5" />}
      </Button>
    </div>
  );
}
