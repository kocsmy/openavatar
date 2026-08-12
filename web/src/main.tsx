import React from "react";
import ReactDOM from "react-dom/client";
import { currentSurface } from "./lib/surface";
import "./index.css";

/*
 * One bundle, one entry, several windows. Each surface is a dynamic import so
 * a window only downloads and parses its own chunk — the menu-bar popover has
 * to feel instant, and it has no business parsing the meetings list.
 */
const Settings = React.lazy(() => import("./App"));
const Main = React.lazy(() => import("./surfaces/Main"));
const Call = React.lazy(() => import("./surfaces/Call"));
const Onboarding = React.lazy(() => import("./surfaces/Onboarding"));
const MenuBar = React.lazy(() => import("./surfaces/MenuBar"));

const surface = currentSurface();
document.documentElement.dataset.surface = surface;

function Surface() {
  switch (surface) {
    case "main":
      return <Main />;
    case "call":
      return <Call />;
    case "onboarding":
      return <Onboarding />;
    case "menu":
      return <MenuBar />;
    default:
      return <Settings />;
  }
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <React.Suspense fallback={<div className="h-screen bg-background" />}>
      <Surface />
    </React.Suspense>
  </React.StrictMode>,
);
