import * as React from "react";
import { bridge } from "@/lib/bridge";
import type { MemoryFact } from "@/lib/types";
import { Hint, Page, Section, useSettings } from "@/components/shared";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Brain, Trash2 } from "lucide-react";

const CATEGORY_ORDER = ["identity", "preference", "project", "person", "commitment", "pattern"];

export function MemoryPage() {
  const { snap } = useSettings();
  const [facts, setFacts] = React.useState<MemoryFact[]>([]);
  const [digests, setDigests] = React.useState<string[]>([]);

  const load = React.useCallback(async () => {
    const r = await bridge("memory.facts");
    setFacts(r.facts);
    setDigests(r.digests);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const empty = facts.length === 0 && digests.length === 0;

  return (
    <Page
      title="Memory"
      description={`What ${snap.settings.assistantName} knows about you — distilled from your calls, used to detect and plan actions with better context. Everything is local; retire anything that's wrong.`}
    >
      {empty ? (
        <div className="flex flex-col items-center gap-2 py-16 text-muted-foreground">
          <Brain className="size-8 opacity-40" />
          <span className="text-sm font-medium">No memory yet</span>
          <span className="text-xs">Facts appear here after your first call.</span>
        </div>
      ) : (
        <>
          {CATEGORY_ORDER.map((category) => {
            const inCategory = facts.filter((f) => f.category === category);
            if (inCategory.length === 0) return null;
            return (
              <Section key={category} title={category[0].toUpperCase() + category.slice(1)}>
                {inCategory.map((fact) => (
                  <div key={fact.id} className="flex items-start justify-between gap-3">
                    <div className="flex flex-col gap-0.5">
                      <span className="text-[13px]" data-selectable>
                        {fact.content}
                      </span>
                      <span className="text-[11px] text-muted-foreground/70">
                        salience {fact.salience.toFixed(1)} · reinforced {fact.lastReinforced}
                      </span>
                    </div>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Retire this fact"
                      onClick={async () => {
                        await bridge("memory.retire", { id: fact.id });
                        void load();
                      }}
                    >
                      <Trash2 className="size-3.5" />
                    </Button>
                  </div>
                ))}
              </Section>
            );
          })}
          {digests.length > 0 && (
            <Section title="Recent call digests">
              {digests.map((digest, i) => (
                <Hint key={i}>{digest}</Hint>
              ))}
            </Section>
          )}
        </>
      )}

      <div className="flex items-center justify-between">
        <Button variant="outline" onClick={() => void load()}>
          Refresh
        </Button>
        <Dialog>
          <DialogTrigger asChild>
            <Button variant="destructive" disabled={empty}>
              Forget everything
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogTitle>Forget everything?</DialogTitle>
            <DialogDescription>
              Retires all memory facts and digests. Calls, decisions, and metrics are kept.
            </DialogDescription>
            <DialogFooter>
              <DialogClose asChild>
                <Button variant="outline">Cancel</Button>
              </DialogClose>
              <DialogClose asChild>
                <Button
                  variant="destructive"
                  onClick={async () => {
                    await bridge("memory.wipe");
                    void load();
                  }}
                >
                  Forget everything
                </Button>
              </DialogClose>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </div>
    </Page>
  );
}
