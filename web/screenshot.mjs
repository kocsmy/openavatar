// Dev tool: render every web surface (mock bridge) headlessly and save
// screenshots — visual verification without the macOS host.
//   npm run build && node screenshot.mjs [outDir] [surface...]
// CHROMIUM env var overrides the browser executable path.
//
// Served over HTTP on purpose: the app serves the same bundle over a custom
// URL scheme, and both answer with real responses. (file:// does not, which is
// what shipped the blank window in v1.31.0.)
import { chromium } from "playwright-core";
import { createServer } from "node:http";
import { mkdir, readFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DIST = join(dirname(fileURLToPath(import.meta.url)), "dist");
const OUT = process.argv[2] ?? "shots";
const ONLY = process.argv.slice(3);
const MIME = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml" };

/** Each window renders at the size the Swift host actually gives it. */
const SURFACES = [
  {
    id: "settings",
    viewport: { width: 1060, height: 780 },
    sections: ["general", "transcription", "models", "integrations", "trust", "memory", "data"],
  },
  {
    id: "main",
    viewport: { width: 1120, height: 760 },
    sections: ["home", "meetings", "followups", "metrics"],
  },
  { id: "call", viewport: { width: 720, height: 640 }, sections: [""] },
  { id: "onboarding", viewport: { width: 760, height: 600 }, sections: [""] },
  // The popover is 380 wide and as tall as its content — capture all of it.
  { id: "menu", viewport: { width: 380, height: 700 }, sections: [""], fullPage: true },
];

const server = createServer(async (req, res) => {
  const path = req.url === "/" ? "/index.html" : req.url.split("?")[0];
  try {
    const data = await readFile(join(DIST, path));
    res.writeHead(200, { "content-type": MIME[extname(path)] ?? "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(4173, r));
await mkdir(OUT, { recursive: true });

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
const wanted = SURFACES.filter((s) => ONLY.length === 0 || ONLY.includes(s.id));

for (const surface of wanted) {
  for (const scheme of ["light", "dark"]) {
    const page = await browser.newPage({
      viewport: surface.viewport,
      deviceScaleFactor: 2,
      colorScheme: scheme,
    });
    for (const section of surface.sections) {
      const url = `http://127.0.0.1:4173/index.html?surface=${surface.id}${section ? `#${section}` : ""}`;
      await page.goto(url);
      await page.waitForTimeout(900);
      const name = section ? `${surface.id}-${section}` : surface.id;
      await page.screenshot({ path: `${OUT}/${name}-${scheme}.png`, fullPage: surface.fullPage ?? false });
      console.log(`${name}-${scheme}`);
    }
    await page.close();
  }
}
await browser.close();
server.close();
console.log("done");
