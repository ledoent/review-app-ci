// Summarize a .lighthouseci/manifest.json into a markdown table (median runs).
// Optional argv[2]: the .lighthouseci directory (lhci writes it relative to
// the --config file's directory, not the cwd).
import fs from "node:fs";

const dir = process.argv[2] || ".lighthouseci";
const manifest = JSON.parse(fs.readFileSync(`${dir}/manifest.json`, "utf8"));
// "—" instead of NaN when a category errored out for a page.
const pct = (v) => (typeof v === "number" && !Number.isNaN(v) ? Math.round(v * 100) : "—");
const rows = manifest
  .filter((r) => r.isRepresentativeRun)
  .map((r) => {
    const s = r.summary ?? {};
    const u = new URL(r.url);
    const path = u.pathname + u.search;
    return `| \`${path}\` | ${pct(s.performance)} | ${pct(s.accessibility)} | ${pct(s["best-practices"])} | ${pct(s.seo)} |`;
  });
const table = ["| page | perf | a11y | best | seo |", "|---|---|---|---|---|", ...rows].join("\n");
fs.writeFileSync("lh-summary.md", table + "\n");
