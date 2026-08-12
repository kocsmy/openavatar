import type { BridgeAPI, BridgeMethod } from "./types";
import { createMockBridge } from "./mock";

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        avatar?: { postMessage: (body: unknown) => Promise<string> };
      };
    };
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
  return mock(method, params);
}

export const isNativeHost = () => Boolean(window.webkit?.messageHandlers?.avatar);

const mock = createMockBridge();
