// Summarize a .lighthouseci/manifest.json into a markdown table (median runs).
import fs from "node:fs";

const manifest = JSON.parse(fs.readFileSync(".lighthouseci/manifest.json", "utf8"));
const pct = (v) => Math.round(v * 100);
const rows = manifest
  .filter((r) => r.isRepresentativeRun)
  .map((r) => {
    const s = r.summary;
    const path = new URL(r.url).pathname;
    return `| \`${path}\` | ${pct(s.performance)} | ${pct(s.accessibility)} | ${pct(s["best-practices"])} | ${pct(s.seo)} |`;
  });
const table = ["| page | perf | a11y | best | seo |", "|---|---|---|---|---|", ...rows].join("\n");
fs.writeFileSync("lh-summary.md", table + "\n");
