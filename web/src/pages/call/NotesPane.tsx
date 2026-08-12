import * as React from "react";
import { bridge } from "@/lib/bridge";
import { Textarea } from "@/components/ui/textarea";

/**
 * The user's own scratchpad — autosaved onto the call record (or, pre-call,
 * the event) and included in exports next to the AI-written meeting notes.
 * Debounced save mirrors CallNotesWindowView.scheduleSave (a 700ms pause).
 *
 * `targetId` names whatever `initialText` belongs to (event id or call id).
 * The draft only reloads from the server when that identity changes — a live
 * call keeps refetching call.state every ~250ms, and re-seeding the draft on
 * every one of those would fight the user's typing.
 */
export function NotesPane({
  targetId,
  initialText,
  placeholder,
}: {
  targetId: string | null;
  initialText: string;
  placeholder: string;
}) {
  const [draft, setDraft] = React.useState(initialText);
  const loadedFor = React.useRef<string | null>(null);
  const saveTimer = React.useRef<number | undefined>(undefined);

  React.useEffect(() => {
    if (loadedFor.current === targetId) return;
    loadedFor.current = targetId;
    setDraft(initialText);
  }, [targetId, initialText]);

  React.useEffect(() => () => window.clearTimeout(saveTimer.current), []);

  const onChange = (text: string) => {
    setDraft(text);
    window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      void bridge("call.saveNotes", { text });
    }, 700);
  };

  return (
    <Textarea
      value={draft}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      className="h-full min-h-0 flex-1 resize-none rounded-none border-0 px-6 py-4 text-[13px] leading-relaxed shadow-none focus-visible:ring-0"
    />
  );
}
