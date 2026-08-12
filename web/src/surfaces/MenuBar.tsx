import * as React from "react";
import { bridge } from "@/lib/bridge";
import { EmptyState, useAutoHeight, useLive } from "@/components/live";
import { Separator } from "@/components/ui/separator";
import type { AssistantMode } from "@/lib/types";
import type { MenuDismissReason, MenuJSONValue } from "@/lib/types/menu";
import { AudioLines, Moon } from "lucide-react";
import { Header } from "@/pages/menu/Header";
import { CallSuggestionBanner, ErrorCard } from "@/pages/menu/Banner";
import { UpcomingSection } from "@/pages/menu/Upcoming";
import { SuggestionsSection } from "@/pages/menu/Suggestions";
import { ApprovalsSection } from "@/pages/menu/Approvals";
import { DetectedSection } from "@/pages/menu/Decisions";
import { ExecutedSection } from "@/pages/menu/Executed";
import { Footer, MenuRows } from "@/pages/menu/Rows";

/*
 * The menu-bar popover — the app's front door. Ported 1:1 from
 * Sources/OpenAvatar/UI/MenuBarView.swift: same sections in the same order,
 * same wording, same actions. What changed is how it's sized (grows with
 * content up to a cap, then scrolls, instead of MenuBarExtra's fixed
 * content-region height — see useAutoHeight and the max-h below) and how the
 * dismiss-reason menu renders (no dropdown-menu primitive in ui/ yet).
 */
export default function MenuBarSurface() {
  // useAutoHeight's RefObject<T | null> return type doesn't line up with the
  // stricter RefObject<T> the ref attribute wants under @types/react 18.
  const ref = useAutoHeight<HTMLDivElement>() as React.RefObject<HTMLDivElement>;
  const { data: snap } = useLive("menu.snapshot", undefined, { topics: ["state"] });
  const { data: settingsSnap } = useLive("settings.snapshot", undefined, { topics: ["state"] });

  // Cmd+Shift+L mirrors the native popover's keyboard shortcut while it's open.
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey && e.shiftKey && e.key.toLowerCase() === "l") {
        e.preventDefault();
        void bridge("menu.toggleListening", {});
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const ready = snap && settingsSnap;
  const hasCallSuggestion = ready ? Boolean(snap.suggestedCallApp) && !snap.isListening : false;
  const hasError = ready ? Boolean(snap.lastError) : false;
  const isEmpty =
    ready &&
    !hasError &&
    snap.suggestions.length === 0 &&
    snap.approvals.length === 0 &&
    snap.detected.length === 0 &&
    snap.executed.length === 0;

  return (
    <div
      ref={ref}
      className="w-[380px] overflow-hidden rounded-xl border border-border/60 bg-popover/85 text-popover-foreground shadow-lg backdrop-blur-xl"
    >
      <Header
        assistantName={settingsSnap?.settings.assistantName ?? "Avatar"}
        isListening={snap?.isListening ?? false}
        systemAudioActive={snap?.systemAudioActive ?? false}
        isPlanning={snap?.isPlanning ?? false}
        isConsolidating={snap?.isConsolidating ?? false}
        onToggle={() => void bridge("menu.toggleListening", {})}
      />
      <Separator className="bg-border/60" />

      {/* One scrollable region for everything below the header — content taller
          than the screen scrolls in here instead of reporting an absurd height. */}
      <div className="max-h-105 overflow-y-auto px-3.5 py-3">
        {ready ? (
          <div className="flex flex-col gap-3.5">
            {hasCallSuggestion ? (
              <CallSuggestionBanner
                appName={snap.suggestedCallApp!}
                onStart={() => void bridge("menu.toggleListening", {})}
              />
            ) : null}
            {hasError ? (
              <ErrorCard
                message={snap.lastError!}
                count={snap.errorLogCount}
                onClear={() => void bridge("menu.clearErrors", {})}
              />
            ) : null}
            {snap.upcoming.length > 0 ? (
              <UpcomingSection
                events={snap.upcoming}
                onOpen={(eventID) => void bridge("menu.openEventNotes", { eventID })}
              />
            ) : null}
            {snap.suggestions.length > 0 ? (
              <SuggestionsSection
                items={snap.suggestions}
                onPrepare={(id) => void bridge("menu.prepareSuggestion", { id })}
                onDismiss={(id) => void bridge("menu.dismissSuggestion", { id })}
              />
            ) : null}
            {snap.approvals.length > 0 ? (
              <ApprovalsSection
                items={snap.approvals}
                onApprove={(approvalID) => void bridge("menu.approve", { approvalID })}
                onDismiss={(decisionID, reason: MenuDismissReason) =>
                  void bridge("menu.dismissDecision", { decisionID, reason })
                }
                onSaveEdit={(approvalID, stepID, editedArguments: Record<string, MenuJSONValue>) =>
                  void bridge("menu.updateApproval", { approvalID, stepID, editedArguments })
                }
              />
            ) : null}
            {snap.detected.length > 0 ? (
              <DetectedSection
                title={snap.isListening ? "Detected this call" : "From your last call"}
                items={snap.detected}
                confidenceThreshold={settingsSnap.settings.confidenceThreshold}
                onPrepare={(decisionID) => void bridge("menu.prepareDecision", { decisionID })}
                onMarkDone={(decisionID) => void bridge("menu.markDone", { decisionID })}
                onDismiss={(decisionID, reason: MenuDismissReason) =>
                  void bridge("menu.dismissDecision", { decisionID, reason })
                }
              />
            ) : null}
            {snap.executed.length > 0 ? (
              <ExecutedSection items={snap.executed} onUndo={(actionID) => void bridge("menu.undo", { actionID })} />
            ) : null}
            {isEmpty ? (
              <EmptyState
                icon={snap.isListening ? AudioLines : Moon}
                title={
                  snap.isListening
                    ? "Listening — decisions will appear here as they come up."
                    : "Not listening. Nothing is recorded until you start."
                }
              />
            ) : null}
          </div>
        ) : (
          <ContentSkeleton />
        )}
      </div>

      <Separator className="bg-border/60" />
      <MenuRows
        version={settingsSnap?.version ?? ""}
        onOpenMain={() => void bridge("window.open", { window: "main" })}
        onCheckUpdates={() => void bridge("app.checkUpdates", {})}
      />
      <Separator className="bg-border/60" />
      <Footer
        assistantName={settingsSnap?.settings.assistantName ?? "Avatar"}
        mode={(settingsSnap?.settings.mode ?? "passive") as AssistantMode}
        onModeChange={(mode) => void bridge("settings.set", { key: "mode", value: mode })}
        onOpenSettings={() => void bridge("window.open", { window: "settings" })}
        onQuit={() => void bridge("menu.quit", {})}
      />
    </div>
  );
}

/** Keeps the panel's shape stable while the first fetch is in flight, so
 * nothing flashes empty and then pops to its real content. */
function ContentSkeleton() {
  return (
    <div className="flex animate-pulse flex-col gap-2 py-1">
      <div className="h-16 rounded-lg bg-muted/70" />
      <div className="h-16 rounded-lg bg-muted/70" />
    </div>
  );
}
