// Dev tool: render every settings page (mock bridge) headlessly and save
// screenshots — visual verification without the macOS host.
//   npm run build && node screenshot.mjs [outDir]
// CHROMIUM env var overrides the browser executable path.
import { chromium } from "playwright-core";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DIST = join(dirname(fileURLToPath(import.meta.url)), "dist");
const OUT = process.argv[2] ?? "shots";
const MIME = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml" };

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

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
for (const scheme of ["light", "dark"]) {
  const page = await browser.newPage({
    viewport: { width: 1060, height: 780 },
    deviceScaleFactor: 2,
    colorScheme: scheme,
  });
  for (const section of ["general", "transcription", "models", "integrations", "trust", "memory", "data"]) {
    await page.goto(`http://127.0.0.1:4173/#${section}`);
    await page.waitForTimeout(800);
    await page.screenshot({ path: `${OUT}/${section}-${scheme}.png` });
  }
  await page.close();
}
await browser.close();
server.close();
console.log("done");
