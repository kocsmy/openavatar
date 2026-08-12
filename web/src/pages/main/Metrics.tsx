import * as React from "react";
import { bridge } from "@/lib/bridge";
import { Toolbar, useLive } from "@/components/live";
import { Button } from "@/components/ui/button";
import type { MetricsDailyRow } from "@/lib/types/metrics";

/**
 * Local metrics dashboard (spec §6). No telemetry leaves the machine; CSV
 * export for dogfooder reporting.
 *
 * Ports Sources/OpenAvatar/UI/MetricsDashboardView.swift (MetricsDashboardTab)
 * 1:1 — including its manual-refresh-only behavior (no live topic here,
 * unlike Home, since the native tab never auto-refreshed either).
 */
export function MetricsPage() {
  const { data, reload } = useLive("metrics.snapshot", {}, { topics: [] });
  const [message, setMessage] = React.useState<string | null>(null);
  const [exporting, setExporting] = React.useState(false);
  const rows = data?.rows ?? [];
  const t = totals(rows);

  return (
    <div className="flex flex-col">
      <Toolbar title="Metrics" />
      <div className="flex flex-col gap-4 px-8 py-6">
        <div className="flex gap-3">
          <StatTile title="Auto-approve w/o edit" value={rate(t.noEdit, t.detected)} caption="primary metric" />
          <StatTile title="Revert rate" value={rate(t.reverted, t.executed)} caption="trust signal" />
          <StatTile title="Decisions detected" value={String(t.detected)} caption="all time" />
          <StatTile title="Misfires dismissed" value={String(t.dismissed)} caption="R2 log" />
        </div>

        <div className="overflow-x-auto rounded-lg border border-border">
          <table className="w-full min-w-[640px] border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-border bg-muted/40 text-left text-xs text-muted-foreground">
                <th className="px-3 py-2 font-medium">Date</th>
                <th className="px-3 py-2 font-medium">Detected</th>
                <th className="px-3 py-2 font-medium">No-edit ✓</th>
                <th className="px-3 py-2 font-medium">Edited</th>
                <th className="px-3 py-2 font-medium">Executed</th>
                <th className="px-3 py-2 font-medium">Reverted</th>
                <th className="px-3 py-2 font-medium">Baseline min</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-3 py-8 text-center text-xs text-muted-foreground">
                    No metrics recorded yet.
                  </td>
                </tr>
              ) : (
                rows.map((r) => (
                  <tr key={r.date} className="border-b border-border last:border-0">
                    <td className="px-3 py-1.5" data-selectable>
                      {r.date}
                    </td>
                    <td className="px-3 py-1.5">{r.decisionsDetected}</td>
                    <td className="px-3 py-1.5">{r.autoApprovedNoEdit}</td>
                    <td className="px-3 py-1.5">{r.edited}</td>
                    <td className="px-3 py-1.5">{r.executed}</td>
                    <td className="px-3 py-1.5">{r.reverted}</td>
                    <td className="px-3 py-1.5">{r.adminMinutesBaseline}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            disabled={exporting}
            onClick={async () => {
              setExporting(true);
              const { message: result } = await bridge("metrics.exportCSV");
              setExporting(false);
              if (result) setMessage(result);
            }}
          >
            Export CSV…
          </Button>
          {message && <span className="text-xs text-muted-foreground">{message}</span>}
          <div className="flex-1" />
          <Button variant="outline" onClick={() => reload()}>
            Refresh
          </Button>
        </div>
      </div>
    </div>
  );
}

function totals(rows: MetricsDailyRow[]) {
  return rows.reduce(
    (acc, r) => ({
      detected: acc.detected + r.decisionsDetected,
      noEdit: acc.noEdit + r.autoApprovedNoEdit,
      edited: acc.edited + r.edited,
      reverted: acc.reverted + r.reverted,
      executed: acc.executed + r.executed,
      dismissed: acc.dismissed + r.dismissed,
    }),
    { detected: 0, noEdit: 0, edited: 0, reverted: 0, executed: 0, dismissed: 0 },
  );
}

function rate(numerator: number, denominator: number): string {
  if (denominator <= 0) return "—";
  return `${Math.round((numerator / denominator) * 100)}%`;
}

function StatTile({ title, value, caption }: { title: string; value: string; caption: string }) {
  return (
    <div className="flex flex-1 flex-col gap-0.5 rounded-lg border border-border bg-card p-2.5">
      <span className="text-xs text-muted-foreground">{title}</span>
      <span className="text-xl font-semibold">{value}</span>
      <span className="text-[11px] text-muted-foreground/70">{caption}</span>
    </div>
  );
}
