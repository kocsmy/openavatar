import type { BridgeAPI, BridgeMethod, EventTopic } from "./types";
import { createMockBridge } from "./mock";
import { mockHandlers } from "./mock/index";

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        avatar?: { postMessage: (body: unknown) => Promise<string> };
      };
    };
    /** Called by the Swift host (WebEventBus) when app state changes. */
    __avatarEvent?: (topic: EventTopic) => void;
    /** Called by the host with each chunk of an answer being written. */
    __avatarStream?: (payload: { id: string; delta?: string }) => void;
  }
}

/**
 * Call into the Swift host. Inside the app, WKScriptMessageHandlerWithReply
 * turns postMessage into a Promise that resolves with a JSON string. Outside
 * the app (vite dev / screenshots) a mock with sample data answers instead,
 * so the whole UI is developable in a plain browser.
 */
export async function bridge<M extends BridgeMethod>(
  method: M,
  params: BridgeAPI[M][0] = {} as BridgeAPI[M][0],
): Promise<BridgeAPI[M][1]> {
  const handler = window.webkit?.messageHandlers?.avatar;
  if (handler) {
    const raw = await handler.postMessage({ method, params });
    return JSON.parse(raw) as BridgeAPI[M][1];
  }
  const own = mockHandlers[method as string];
  if (own) return (await own(params as Record<string, unknown>)) as BridgeAPI[M][1];
  return settingsMock(method, params);
}

export const isNativeHost = () => Boolean(window.webkit?.messageHandlers?.avatar);

const settingsMock = createMockBridge();

/*
 * Push channel. Swift owns the truth; rather than diffing state across the
 * boundary we send a topic and the page refetches what it needs. Coarse on
 * purpose — a stale window is a bug, a redundant fetch is a few milliseconds.
 */
type Listener = (topic: EventTopic) => void;
const listeners = new Set<Listener>();

window.__avatarEvent = (topic: EventTopic) => {
  for (const l of listeners) l(topic);
};

/** Subscribe to host events. Returns an unsubscribe function. */
export function onEvent(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Fire an event locally — used by mocks and by pages after their own writes. */
export function emitLocal(topic: EventTopic) {
  window.__avatarEvent?.(topic);
}

/*
 * Streamed answers. The only host push that carries data rather than a nudge:
 * a token can't be refetched, and waiting for the finished reply is the thing
 * streaming exists to avoid. The bridge call still resolves with the whole
 * answer, so these deltas are strictly an early view of it — a page that never
 * receives one still ends up correct.
 */
type StreamListener = (delta: string) => void;
const streams = new Map<string, StreamListener>();
let streamCounter = 0;

window.__avatarStream = (payload) => {
  if (!payload?.id || typeof payload.delta !== "string") return;
  streams.get(payload.id)?.(payload.delta);
};

/** Claim a stream id and start listening. Returns the id and a stop function. */
export function openStream(listener: StreamListener): { id: string; close: () => void } {
  const id = `s${++streamCounter}-${Date.now()}`;
  streams.set(id, listener);
  return { id, close: () => streams.delete(id) };
}

/** Feed a stream locally — used by the mocks to imitate the host's push. */
export function emitStreamLocal(id: string, delta: string) {
  window.__avatarStream?.({ id, delta });
}

/**
 * Tell the host how tall the content is. Only the menu-bar popover and the
 * floating prompts listen; windows ignore it.
 */
export function reportHeight(height: number) {
  if (!isNativeHost()) return;
  void bridge("ui.resize", { height: Math.ceil(height) });
}
