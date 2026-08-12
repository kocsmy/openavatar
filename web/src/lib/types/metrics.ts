/** Metrics surface bridge contract. Mirrors Sources/OpenAvatar/WebUI/Bridges/MetricsBridge.swift. */

/** One day's counters — mirrors MetricsRecorder.DailyRow (Store/MetricsRecorder.swift). */
export interface MetricsDailyRow {
  date: string;
  decisionsDetected: number;
  autoApprovedNoEdit: number;
  edited: number;
  reverted: number;
  dismissed: number;
  executed: number;
  adminMinutesBaseline: number;
}

export interface MetricsSnapshot {
  /** All days on record, newest first. */
  rows: MetricsDailyRow[];
}

export interface MetricsAPI {
  "metrics.snapshot": [Record<string, never>, MetricsSnapshot];
  /** Opens a native Save panel; message is "" (leave prior message as-is) if the user cancels. */
  "metrics.exportCSV": [Record<string, never>, { message: string }];
}
