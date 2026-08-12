import * as React from "react";
import { bridge } from "@/lib/bridge";
import type { SecretKey, Settings, Snapshot } from "@/lib/types";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { cn } from "@/lib/utils";
import { Check, KeyRound } from "lucide-react";

// MARK: Settings context — one snapshot, optimistic writes through the bridge.

interface SettingsContextValue {
  snap: Snapshot;
  set: <K extends keyof Settings>(key: K, value: Settings[K]) => void;
  markSecretSaved: (key: SecretKey) => void;
  patchCalendar: (connected: boolean) => void;
  reload: () => Promise<void>;
}

const SettingsContext = React.createContext<SettingsContextValue | null>(null);

export function useSettings(): SettingsContextValue {
  const ctx = React.useContext(SettingsContext);
  if (!ctx) throw new Error("useSettings outside provider");
  return ctx;
}

export function SettingsProvider({ children }: { children: React.ReactNode }) {
  const [snap, setSnap] = React.useState<Snapshot | null>(null);

  const reload = React.useCallback(async () => {
    setSnap(await bridge("settings.snapshot"));
  }, []);

  React.useEffect(() => {
    void reload();
  }, [reload]);

  const value = React.useMemo<SettingsContextValue | null>(() => {
    if (!snap) return null;
    return {
      snap,
      set: (key, value) => {
        setSnap((s) => (s ? { ...s, settings: { ...s.settings, [key]: value } } : s));
        void bridge("settings.set", { key, value });
      },
      markSecretSaved: (key) => {
        setSnap((s) => (s ? { ...s, secrets: { ...s.secrets, [key]: true } } : s));
      },
      patchCalendar: (connected) => {
        setSnap((s) =>
          s
            ? {
                ...s,
                calendar: { ...s.calendar, connected },
                settings: { ...s.settings, calendarEnabled: connected },
              }
            : s,
        );
      },
      reload,
    };
  }, [snap, reload]);

  if (!value) {
    return (
      <div className="flex h-screen items-center justify-center text-sm text-muted-foreground">
        Loading settings…
      </div>
    );
  }
  return <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>;
}

// MARK: Layout primitives

export function Page({
  title,
  description,
  children,
}: {
  title: string;
  description: string;
  children: React.ReactNode;
}) {
  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-4 px-8 py-7">
      <div className="flex flex-col gap-1">
        <h1 className="text-lg font-semibold tracking-tight">{title}</h1>
        <p className="text-xs text-muted-foreground">{description}</p>
      </div>
      {children}
    </div>
  );
}

export function Section({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {description ? <CardDescription>{description}</CardDescription> : null}
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

/** Label on the left, control on the right — the macOS Form rhythm. */
export function Row({
  label,
  hint,
  children,
  align = "center",
}: {
  label: React.ReactNode;
  hint?: React.ReactNode;
  children: React.ReactNode;
  align?: "center" | "start";
}) {
  return (
    <div className="flex flex-col gap-1">
      <div className={cn("grid grid-cols-[190px_1fr] gap-3", align === "center" ? "items-center" : "items-start")}>
        <Label className="text-muted-foreground font-normal">{label}</Label>
        <div className="flex min-w-0 items-center gap-2">{children}</div>
      </div>
      {hint ? <Hint className="ml-[202px]">{hint}</Hint> : null}
    </div>
  );
}

export function Hint({ className, children }: { className?: string; children: React.ReactNode }) {
  return <p className={cn("text-xs leading-relaxed text-muted-foreground", className)}>{children}</p>;
}

export function Status({
  ok,
  mono = false,
  children,
}: {
  ok?: boolean;
  mono?: boolean;
  children: React.ReactNode;
}) {
  return (
    <p
      data-selectable
      className={cn(
        "text-xs leading-relaxed break-words",
        mono && "font-mono text-[11px]",
        ok === true && "text-success",
        ok === false && "text-destructive",
        ok === undefined && "text-muted-foreground",
      )}
    >
      {children}
    </p>
  );
}

/** Text setting that commits on blur / Enter, not per keystroke. */
export function TextSetting({
  value,
  onCommit,
  placeholder,
  type = "text",
  className,
}: {
  value: string;
  onCommit: (value: string) => void;
  placeholder?: string;
  type?: string;
  className?: string;
}) {
  const [draft, setDraft] = React.useState(value);
  React.useEffect(() => setDraft(value), [value]);
  const commit = () => {
    if (draft !== value) onCommit(draft);
  };
  return (
    <Input
      type={type}
      value={draft}
      placeholder={placeholder}
      className={className}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={commit}
      onKeyDown={(e) => {
        if (e.key === "Enter") (e.target as HTMLInputElement).blur();
      }}
    />
  );
}

/**
 * Paste → Save → confirmation, never pre-filling the real secret — the same
 * contract as the native SecretField.
 */
export function SecretField({
  label,
  saved,
  onSave,
}: {
  label: string;
  saved: boolean;
  onSave: (value: string) => void | Promise<void>;
}) {
  const [draft, setDraft] = React.useState("");
  const [justSaved, setJustSaved] = React.useState(false);
  return (
    <div className="flex w-full items-center gap-2">
      <Input
        type="password"
        autoComplete="off"
        value={draft}
        placeholder={saved ? `${label} — saved ✓ (paste to replace)` : label}
        onChange={(e) => setDraft(e.target.value)}
      />
      <Button
        variant="secondary"
        disabled={!draft}
        onClick={async () => {
          await onSave(draft);
          setDraft("");
          setJustSaved(true);
          setTimeout(() => setJustSaved(false), 2500);
        }}
      >
        Save
      </Button>
      {justSaved ? (
        <span className="flex items-center gap-1 text-xs text-success">
          <Check className="size-3.5" /> Saved
        </span>
      ) : saved ? (
        <KeyRound className="size-3.5 shrink-0 text-success" aria-label="A token is saved in the Keychain" />
      ) : null}
    </div>
  );
}

/** Live status chip on engine cards and integration rows. */
export function Chip({
  tone,
  children,
}: {
  tone: "success" | "warning" | "destructive" | "muted";
  children: React.ReactNode;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold",
        tone === "success" && "bg-success/12 text-success",
        tone === "warning" && "bg-warning/14 text-warning",
        tone === "destructive" && "bg-destructive/12 text-destructive",
        tone === "muted" && "bg-secondary text-muted-foreground",
      )}
    >
      {children}
    </span>
  );
}

export function Spinner() {
  return (
    <span className="inline-block size-3.5 animate-spin rounded-full border-2 border-muted-foreground/30 border-t-muted-foreground" />
  );
}

export function ExternalLink({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <button
      className="cursor-pointer text-primary underline-offset-2 hover:underline text-[13px]"
      onClick={() => void bridge("app.openURL", { url: href })}
    >
      {children}
    </button>
  );
}
