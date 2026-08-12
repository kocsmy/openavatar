import * as React from "react";
import { bridge } from "@/lib/bridge";
import type { AssistantMode, TrustChoice, TrustRow } from "@/lib/types";
import { Hint, Page, Section, useSettings } from "@/components/shared";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { cn } from "@/lib/utils";

export function TrustPage() {
  const { snap } = useSettings();
  const [rows, setRows] = React.useState<TrustRow[]>([]);
  const [threshold, setThreshold] = React.useState(10);

  React.useEffect(() => {
    void bridge("trust.rows").then((r) => {
      setRows(r.rows);
      setThreshold(r.graduationThreshold);
    });
  }, []);

  const update = async (tool: string, mode: AssistantMode, setting: TrustChoice) => {
    setRows((rs) => rs.map((r) => (r.tool === tool ? { ...r, [mode]: setting } : r)));
    await bridge("trust.set", { tool, mode, setting });
  };

  const native = rows.filter((r) => !r.dynamic);
  const dynamic = rows.filter((r) => r.dynamic);

  return (
    <Page
      title="Trust"
      description={`Per action type, choose whether ${snap.settings.assistantName} asks first or acts autonomously.`}
    >
      <Section title="Trust ladder">
        <Hint>
          Destructive actions (red) unlock Autonomous only after {threshold} approved executions
          without a revert or edit. Requests spoken by other call participants always require
          approval for destructive actions, regardless of this matrix.
        </Hint>
        <div className="grid grid-cols-[1fr_150px_150px] items-center gap-x-3 gap-y-1.5">
          <span className="text-[11px] font-semibold text-muted-foreground">Action</span>
          <span className="text-center text-[11px] font-semibold text-muted-foreground">Passive</span>
          <span className="text-center text-[11px] font-semibold text-muted-foreground">Active</span>
          {native.map((row) => (
            <MatrixRow key={row.tool} row={row} threshold={threshold} onChange={update} />
          ))}
        </div>
        {dynamic.length > 0 && (
          <>
            <Separator />
            <span className="text-[11px] font-semibold text-muted-foreground">
              From manifests &amp; MCP servers
            </span>
            <div className="grid grid-cols-[1fr_150px_150px] items-center gap-x-3 gap-y-1.5">
              {dynamic.map((row) => (
                <MatrixRow key={row.tool} row={row} threshold={threshold} onChange={update} />
              ))}
            </div>
          </>
        )}
      </Section>
    </Page>
  );
}

function MatrixRow({
  row,
  threshold,
  onChange,
}: {
  row: TrustRow;
  threshold: number;
  onChange: (tool: string, mode: AssistantMode, setting: TrustChoice) => void;
}) {
  const locked = row.risk === "destructive" && !row.graduated;
  return (
    <React.Fragment>
      <div className="flex min-w-0 items-center gap-1.5">
        <span
          className={cn(
            "size-1.5 shrink-0 rounded-full",
            row.risk === "destructive" ? "bg-destructive" : "bg-warning/70",
          )}
        />
        <span className="truncate font-mono text-xs" data-selectable>
          {row.tool}
        </span>
      </div>
      {(["passive", "active"] as const).map((mode) => (
        <Select
          key={mode}
          value={row[mode]}
          disabled={locked}
          onValueChange={(v) => onChange(row.tool, mode, v as TrustChoice)}
        >
          <SelectTrigger
            className="h-6.5 text-xs"
            title={
              locked
                ? `Needs ${threshold} approved, unreverted executions before Autonomous unlocks.`
                : undefined
            }
          >
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="ask_first">Ask first</SelectItem>
            <SelectItem value="autonomous">Autonomous</SelectItem>
          </SelectContent>
        </Select>
      ))}
    </React.Fragment>
  );
}
