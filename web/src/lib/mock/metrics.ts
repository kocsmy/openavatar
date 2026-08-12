import type { MockHandlers } from "./index";
import { delay } from "./index";
import type { MetricsDailyRow } from "../types/metrics";

/** Browser-only sample data for the metrics surface — two weeks of dogfooding. */
const rows: MetricsDailyRow[] = [
  { date: "2026-08-12", decisionsDetected: 6, autoApprovedNoEdit: 4, edited: 1, reverted: 0, dismissed: 1, executed: 5, adminMinutesBaseline: 25 },
  { date: "2026-08-11", decisionsDetected: 9, autoApprovedNoEdit: 6, edited: 2, reverted: 1, dismissed: 1, executed: 8, adminMinutesBaseline: 30 },
  { date: "2026-08-10", decisionsDetected: 4, autoApprovedNoEdit: 3, edited: 0, reverted: 0, dismissed: 1, executed: 3, adminMinutesBaseline: 15 },
  { date: "2026-08-08", decisionsDetected: 11, autoApprovedNoEdit: 7, edited: 3, reverted: 1, dismissed: 0, executed: 10, adminMinutesBaseline: 35 },
  { date: "2026-08-07", decisionsDetected: 7, autoApprovedNoEdit: 5, edited: 1, reverted: 0, dismissed: 1, executed: 6, adminMinutesBaseline: 20 },
];

export const metricsMocks: MockHandlers = {
  "metrics.snapshot": async () => ({ rows }),
  "metrics.exportCSV": async () => {
    await delay(400);
    return { message: "Exported to openavatar-metrics.csv" };
  },
};
