import * as React from "react";
import { bridge } from "@/lib/bridge";
import type { ErrorEntry } from "@/lib/types";
import { Hint, Page, Row, Section, Status, useSettings } from "@/components/shared";
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

export function DataPage() {
  const { snap } = useSettings();
  const [errors, setErrors] = React.useState<ErrorEntry[]>([]);
  const [message, setMessage] = React.useState("");

  React.useEffect(() => {
    void bridge("errors.recent").then((r) => setErrors(r.errors));
  }, []);

  return (
    <Page title="Data" description="Local-first: everything lives in SQLite on this Mac.">
      <Section title="Local-first data">
        <Hint>
          Transcripts, decisions, actions, and metrics live in a local SQLite database. They never
          leave this Mac except as LLM/STT payloads you explicitly configured.
        </Hint>
        <Row label="Database">
          <span className="break-all font-mono text-[11px] text-muted-foreground" data-selectable>
            {snap.dbPath}
          </span>
        </Row>
      </Section>

      {errors.length > 0 && (
        <Section title="Error log (this session)">
          {errors.map((entry, i) => (
            <div key={i} className="flex flex-col gap-0.5">
              <span className="text-[11px] text-muted-foreground/70">{entry.at}</span>
              <Status mono>{entry.message}</Status>
            </div>
          ))}
          <div>
            <Button
              variant="outline"
              onClick={async () => {
                await bridge("errors.clear");
                setErrors([]);
              }}
            >
              Clear error log
            </Button>
          </div>
        </Section>
      )}

      <Section title="Export & erase">
        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            onClick={async () => {
              const { message } = await bridge("data.export");
              setMessage(message);
            }}
          >
            Export all data (JSON)…
          </Button>
          <Dialog>
            <DialogTrigger asChild>
              <Button variant="destructive">Delete all data</Button>
            </DialogTrigger>
            <DialogContent>
              <DialogTitle>Delete all local data?</DialogTitle>
              <DialogDescription>This cannot be undone.</DialogDescription>
              <DialogFooter>
                <DialogClose asChild>
                  <Button variant="outline">Cancel</Button>
                </DialogClose>
                <DialogClose asChild>
                  <Button
                    variant="destructive"
                    onClick={async () => {
                      await bridge("data.eraseAll");
                      setMessage("All local data deleted.");
                    }}
                  >
                    Delete everything
                  </Button>
                </DialogClose>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </div>
        {message && <Hint>{message}</Hint>}
      </Section>
    </Page>
  );
}
