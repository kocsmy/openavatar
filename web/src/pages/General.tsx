import * as React from "react";
import { bridge } from "@/lib/bridge";
import { ExternalLink, Hint, Page, Row, Section, TextSetting, useSettings } from "@/components/shared";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Slider } from "@/components/ui/slider";
import { Switch } from "@/components/ui/switch";

export function GeneralPage() {
  const { snap, set } = useSettings();
  const s = snap.settings;
  const [checkingUpdates, setCheckingUpdates] = React.useState(false);

  return (
    <Page title="General" description="Identity, mode, and how calls are picked up.">
      <Section title="Assistant">
        <Row
          label="Assistant name (wake phrase)"
          hint={`In Active mode, say “${s.assistantName}, …” on a call to trigger immediate execution.`}
        >
          <TextSetting value={s.assistantName} onCommit={(v) => set("assistantName", v)} />
        </Row>
        <Row label="Your name" hint="Used in email attribution.">
          <TextSetting value={s.userDisplayName} onCommit={(v) => set("userDisplayName", v)} />
        </Row>
      </Section>

      <Section
        title="Mode"
        description="Passive: decisions accumulate into a post-call review. Active: executes immediately when you address the assistant directly (subject to the Trust matrix)."
      >
        <RadioGroup value={s.mode} onValueChange={(v) => set("mode", v as typeof s.mode)}>
          <div className="flex items-center gap-2">
            <RadioGroupItem value="passive" id="mode-passive" />
            <Label htmlFor="mode-passive">Passive</Label>
          </div>
          <div className="flex items-center gap-2">
            <RadioGroupItem value="active" id="mode-active" />
            <Label htmlFor="mode-active">Active</Label>
          </div>
        </RadioGroup>
      </Section>

      <Section title="Calls">
        <Row
          label="Auto-start on calls"
          hint="When Zoom, Teams, Slack, or a browser meeting takes the microphone, notes start by themselves and stop when the call ends — you'll get a notification each time. Off keeps the manual Start button and the menu-bar suggestion."
        >
          <Switch checked={s.autoStartOnCall} onCheckedChange={(v) => set("autoStartOnCall", v)} />
        </Row>
        <Row
          label="Offer to join upcoming meetings"
          hint="A minute before a calendar event starts, a small prompt shows the meeting and who's on it — one click opens the Zoom/Meet link with notes already running. Requires Google Calendar in Integrations."
        >
          <Switch checked={s.meetingPromptEnabled} onCheckedChange={(v) => set("meetingPromptEnabled", v)} />
        </Row>
      </Section>

      <Section title="Detection">
        <Row
          label={`Confidence threshold: ${s.confidenceThreshold.toFixed(2)}`}
          hint="Decisions below this confidence are greyed out and never auto-executed."
        >
          <Slider
            min={0.3}
            max={0.9}
            step={0.05}
            value={[s.confidenceThreshold]}
            onValueChange={([v]) => set("confidenceThreshold", v)}
            className="max-w-56"
          />
        </Row>
      </Section>

      <Section title="Updates">
        <Row label="Version">
          <span className="text-[13px]" data-selectable>
            {snap.version}
          </span>
        </Row>
        <Row
          label="Updates"
          hint="Updates download automatically in the background; you'll be asked to relaunch when one is ready."
        >
          <Button
            variant="outline"
            disabled={checkingUpdates}
            onClick={async () => {
              setCheckingUpdates(true);
              await bridge("app.checkUpdates");
              setTimeout(() => setCheckingUpdates(false), 1500);
            }}
          >
            Check for updates now
          </Button>
        </Row>
      </Section>

      <Section title="About & legal">
        <div className="flex items-center gap-4">
          <ExternalLink href="https://github.com/kocsmy/openavatar/blob/main/PRIVACY.md">
            Privacy Policy
          </ExternalLink>
          <ExternalLink href="https://github.com/kocsmy/openavatar/blob/main/TERMS.md">
            Terms of Service
          </ExternalLink>
        </div>
        <Hint>
          Everything runs on your Mac. OpenAvatar has no servers and collects no data — see the policy
          for details.
        </Hint>
        <div>
          <Button variant="outline" onClick={() => void bridge("app.rerunOnboarding")}>
            Re-run onboarding
          </Button>
        </div>
      </Section>
    </Page>
  );
}
