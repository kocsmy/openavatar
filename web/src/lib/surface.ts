/**
 * One bundle, several windows. The Swift host loads
 * `openavatar-ui://app/index.html?surface=<id>`; each surface is a separate
 * lazily-loaded chunk, so the menu-bar popover doesn't parse the meetings UI.
 */
export type SurfaceID = "settings" | "main" | "call" | "onboarding" | "menu";

const SURFACES: SurfaceID[] = ["settings", "main", "call", "onboarding", "menu"];

export function currentSurface(): SurfaceID {
  const param = new URLSearchParams(window.location.search).get("surface");
  return SURFACES.includes(param as SurfaceID) ? (param as SurfaceID) : "settings";
}
