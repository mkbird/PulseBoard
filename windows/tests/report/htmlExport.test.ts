import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runInNewContext } from "node:vm";

import { prepareWindowsHTML } from "../../src/server.ts";

const browserScript = fs.readFileSync(path.resolve(process.cwd(), "report-export.js"), "utf8");

test("Windows console installs HTML export without changing the shared source", () => {
  const source = fs.readFileSync(path.resolve(process.cwd(), "../Sources/PulseBoard/Resources/web_console.html"), "utf8");
  const result = prepareWindowsHTML(source, browserScript);
  assert.match(result, /CliptoPulse Windows/);
  assert.match(result, /HTML \/ Markdown \/ CSV/);
  assert.match(result, /⬇️ 下载 HTML/);
  assert.match(result, /<script>[\s\S]*<\/script>\s*<\/body>/);
  assert.match(source, /__CLIPTOPULSE_BUILD_LABEL__/);
  assert.throws(() => prepareWindowsHTML("<html></html>", browserScript), /insertion points/);
});

test("Windows button downloads a standalone, printable HTML report", async () => {
  let click: (() => void) | undefined;
  let downloaded: { blob: Blob; filename: string } | undefined;
  let toast = "";
  const replacement = {
    textContent: "",
    title: "",
    addEventListener(event: string, callback: () => void) {
      if (event === "click") click = callback;
    }
  };
  const previous = {
    cloneNode() { return replacement; },
    replaceWith(next: typeof replacement) { elements.set("download-img-btn", next); }
  };
  const elements = new Map<string, any>([
    ["download-img-btn", previous],
    ["md-raw-output", { value: "# 晨报\n\n| 指标 | 数值 |\n| --- | --- |\n| 速度 | 2.5x |" }],
    ["rpt-filename-badge", { textContent: "Clipto晨报_20261029.md" }]
  ]);
  const context = {
    document: { getElementById: (id: string) => elements.get(id) },
    Blob,
    renderGFMToHTML: (markdown: string) => `<h1>${markdown.split("\n")[0]?.slice(2)}</h1><table><tr><td>2.5x</td></tr></table>`,
    downloadBlob: (blob: Blob, filename: string) => { downloaded = { blob, filename }; },
    showToast: (message: string) => { toast = message; }
  };

  runInNewContext(browserScript, context);
  assert.equal(elements.get("download-img-btn"), replacement);
  assert.equal(replacement.textContent, "⬇️ 下载 HTML");
  assert.ok(click);
  click();

  assert.equal(downloaded?.filename, "Clipto晨报_20261029.html");
  assert.equal(downloaded?.blob.type, "text/html;charset=utf-8");
  const html = await downloaded!.blob.text();
  assert.match(html, /^<!doctype html>/);
  assert.match(html, /<meta charset="utf-8">/);
  assert.match(html, /<main class="report">/);
  assert.match(html, /<table>/);
  assert.match(html, /@media print/);
  assert.doesNotMatch(html, /<script|https?:\/\//);
  assert.match(toast, /已下载/);
});
