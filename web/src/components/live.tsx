import * as React from "react";
import { bridge, onEvent, reportHeight } from "@/lib/bridge";
import type { BridgeAPI, BridgeMethod, EventTopic } from "@/lib/types";
import { cn } from "@/lib/utils";

/**
 * Read-through state for a bridge method: fetch on mount, refetch whenever the
 * host says something changed. The host pushes a topic, not a diff — a page is
 * always one fetch away from being right, which beats replicating app state on
 * this side of the boundary.
 */
export function useLive<M extends BridgeMethod>(
  method: M,
  params?: BridgeAPI[M][0],
  options: { topics?: EventTopic[]; pollMs?: number } = {},
): {
  data: BridgeAPI[M][1] | null;
  error: string | null;
  loading: boolean;
  reload: () => void;
} {
  const { topics = ["state"], pollMs } = options;
  const [data, setData] = React.useState<BridgeAPI[M][1] | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(true);
  // Params are compared by value: callers pass object literals inline.
  const key = JSON.stringify(params ?? {});
  const topicKey = topics.join(",");

  const load = React.useCallback(async () => {
    try {
      const result = await bridge(method, JSON.parse(key) as BridgeAPI[M][0]);
      setData(result);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [method, key]);

  React.useEffect(() => {
    void load();
    let timer: number | undefined;
    // Coalesce bursts: state changes arrive per keystroke of a transcript.
    let pending: number | undefined;
    const unsubscribe = onEvent((topic) => {
      if (!topicKey.split(",").includes(topic)) return;
      window.clearTimeout(pending);
      pending = window.setTimeout(() => void load(), 120);
    });
    if (pollMs) timer = window.setInterval(() => void load(), pollMs);
    return () => {
      unsubscribe();
      window.clearTimeout(pending);
      if (timer) window.clearInterval(timer);
    };
  }, [load, topicKey, pollMs]);

  return { data, error, loading, reload: () => void load() };
}

/**
 * Keep the host window sized to the content. Only the popover acts on it, but
 * measuring is harmless elsewhere.
 */
export function useAutoHeight<T extends HTMLElement>(): React.RefObject<T | null> {
  const ref = React.useRef<T>(null);
  React.useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const observer = new ResizeObserver(() => reportHeight(node.getBoundingClientRect().height));
    observer.observe(node);
    reportHeight(node.getBoundingClientRect().height);
    return () => observer.disconnect();
  }, []);
  return ref;
}

export function EmptyState({
  icon: Icon,
  title,
  description,
  action,
}: {
  icon?: React.ComponentType<{ className?: string }>;
  title: string;
  description?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-6 py-14 text-center">
      {Icon ? <Icon className="size-7 text-muted-foreground/40" /> : null}
      <p className="text-sm font-medium">{title}</p>
      {description ? (
        <p className="max-w-sm text-xs leading-relaxed text-muted-foreground">{description}</p>
      ) : null}
      {action ? <div className="pt-1">{action}</div> : null}
    </div>
  );
}

/** Sticky window header: title on the left, actions on the right. */
export function Toolbar({
  title,
  subtitle,
  children,
  className,
}: {
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  children?: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "sticky top-0 z-10 flex items-center gap-3 border-b border-border bg-background/85 px-6 py-3 backdrop-blur",
        className,
      )}
    >
      <div className="min-w-0 flex-1">
        <h1 className="truncate text-[15px] font-semibold tracking-tight">{title}</h1>
        {subtitle ? <p className="truncate text-xs text-muted-foreground">{subtitle}</p> : null}
      </div>
      {children}
    </div>
  );
}

/** "3 minutes ago" for ISO-8601 strings coming from Swift. */
export function relativeTime(iso: string): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "";
  const seconds = Math.round((Date.now() - then) / 1000);
  const future = seconds < 0;
  const s = Math.abs(seconds);
  const units: [number, Intl.RelativeTimeFormatUnit][] = [
    [60, "second"],
    [3600, "minute"],
    [86400, "hour"],
    [604800, "day"],
  ];
  const fmt = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  if (s < 45) return future ? "in a moment" : "just now";
  for (const [limit, unit] of units) {
    if (s < limit * 60 || unit === "day") {
      const divisor = unit === "second" ? 1 : unit === "minute" ? 60 : unit === "hour" ? 3600 : 86400;
      const value = Math.round(s / divisor);
      if (unit === "day" && value > 6) break;
      return fmt.format(future ? value : -value, unit);
    }
  }
  return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export function formatTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

export function formatDuration(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const h = Math.floor(m / 60);
  if (h > 0) return `${h}h ${m % 60}m`;
  if (m > 0) return `${m}m`;
  return `${Math.max(0, Math.round(seconds))}s`;
}
