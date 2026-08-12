import * as React from "react";

/**
 * Shared pieces every step uses (mirrors StepHeader/FeatureRow in the
 * SwiftUI source) — an icon-led headline, then a stack of feature rows.
 */
export function StepHeader({
  icon: Icon,
  title,
  subtitle,
}: {
  icon: React.ElementType;
  title: string;
  subtitle: string;
}) {
  return (
    <div className="flex flex-col items-center gap-3 pb-7 text-center">
      <div className="grid size-14 place-items-center rounded-2xl bg-primary/10 text-primary">
        <Icon className="size-7" strokeWidth={1.75} />
      </div>
      <h2 className="text-[22px] font-semibold tracking-tight">{title}</h2>
      <p className="max-w-md text-[14px] leading-relaxed text-muted-foreground">{subtitle}</p>
    </div>
  );
}

export function FeatureRow({
  icon: Icon,
  title,
  detail,
}: {
  icon: React.ComponentType<{ className?: string }>;
  title: string;
  detail: React.ReactNode;
}) {
  return (
    <div className="flex items-start gap-3.5">
      <div className="mt-0.5 grid size-8 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary">
        <Icon className="size-4" />
      </div>
      <div className="flex min-w-0 flex-col gap-0.5">
        <span className="text-[13.5px] font-semibold">{title}</span>
        <p className="text-[13px] leading-relaxed text-muted-foreground">{detail}</p>
      </div>
    </div>
  );
}

/** Centered column every step's body sits in — keeps line lengths readable. */
export function StepBody({
  className,
  children,
}: {
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={`flex w-full flex-col items-center ${className ?? ""}`}>
      <div className="flex w-full max-w-lg flex-col gap-4">{children}</div>
    </div>
  );
}
