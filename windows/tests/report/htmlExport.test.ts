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

test("Windows headline retains GPU P95 and adds both process VRAM cards while Mac markdown is untouched", () => {
  const original = "# 晨报\n\n## 🎯 头条指标\n\n| 原来的六项 |\n\n## 一、吞吐概览\n\n原有正文\n";
  const elements = new Map<string, any>([
    ["md-raw-output", { value: "" }], ["md-rendered-preview", { innerHTML: "" }],
  ]);
  const fixture = {
    environment: { platform: "windows" },
    scopes: { asset_analysis: { wall_speedup: 3 } },
    aligned_hardware: {
      has_data: true,
      clipto_cpu_percent: { p95: 400 }, clipto_gpu_percent: { p95: 75 },
      cms_total_memory_bytes: { max: 2 }, clipto_memory_bytes: { max: 3 },
      cms_total_vram_bytes: { max: 4 }, clipto_vram_bytes: { max: 5 },
    },
  };
  const context: Record<string, any> = {
    dagscData: fixture,
    document: { getElementById: (id: string) => elements.get(id), createElement: () => ({}), head: { appendChild() {} } },
    buildMarkdownFromCurrentState: () => original,
    rebuildMarkdownReport: () => {},
    renderGFMToHTML: (markdown: string) => markdown,
    formatBytes: (value: number) => `${value} GB`,
    formatPct: (value: number) => `${value}%`,
    formatSpeedup: (value: number) => `${value}x`,
  };
  runInNewContext(browserScript, context);
  const markdown: string = context.buildMarkdownFromCurrentState();
  const labels = markdown.split("\n").find(line => line.startsWith("| 端到端"))!;
  assert.equal(labels.split("|").filter(cell => cell.trim()).length, 8);
  assert.match(labels, /Clipto 进程组 GPU P95/);
  assert.match(labels, /全 CMS 显存占用峰值/);
  assert.match(labels, /Clipto 显存占用峰值/);
  assert.match(markdown, /\*\*75%\*\*/);
  assert.match(markdown, /\*\*4 GB\*\*/);
  assert.match(markdown, /\*\*5 GB\*\*/);
  assert.match(markdown, /原有正文/);
  context.dagscData = { ...fixture, environment: { platform: "macos" } };
  assert.equal(context.buildMarkdownFromCurrentState(), original);
  context.dagscData = { ...fixture, aligned_hardware: { has_data: false } };
  assert.match(context.buildMarkdownFromCurrentState(), /\*\*未采集\*\*/);
});

test("actual Markdown renderer exports eight readable cards in the Windows offline HTML", async () => {
  const source = fs.readFileSync(path.resolve(process.cwd(), "../Sources/PulseBoard/Resources/web_console.html"), "utf8");
  const renderer = source.slice(source.indexOf("function renderGFMToHTML(md)"), source.indexOf("function rebuildMarkdownReport()"));
  let click: (() => void) | undefined;
  let artifact: Blob | undefined;
  const elements = new Map<string, any>([
    ["download-img-btn", {
      cloneNode: () => ({ addEventListener: (_event: string, handler: () => void) => { click = handler; } }),
      replaceWith() {},
    }],
    ["md-raw-output", { value: "" }], ["md-rendered-preview", { innerHTML: "" }],
    ["rpt-filename-badge", { textContent: "Windows头条排版验收_示例数据.md" }],
  ]);
  const context: Record<string, any> = {
    document: { getElementById: (id: string) => elements.get(id), createElement: () => ({}), head: { appendChild() {} } },
    Blob,
    dagscData: {
      environment: { platform: "windows" }, scopes: { asset_analysis: { wall_speedup: 3.25 } },
      aligned_hardware: {
        has_data: true, clipto_cpu_percent: { p95: 320 }, clipto_gpu_percent: { p95: 76.4 },
        cms_total_memory_bytes: { max: 8.5 }, clipto_memory_bytes: { max: 12.2 },
        cms_total_vram_bytes: { max: 6.1 }, clipto_vram_bytes: { max: 7.3 }, storage: { end_bytes: 120 },
      },
    },
    escHtml: (value: unknown) => String(value).replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]!),
    buildMarkdownFromCurrentState: () => "# Windows 头条排版验收（示例数据）\n\n## 🎯 头条指标\n\n旧版头条\n\n## 一、验收说明\n\n以下数值用于验证排版，非实际运行数据。\n",
    rebuildMarkdownReport: () => {}, formatBytes: (value: number) => `${value} GB`,
    formatPct: (value: number) => `${value}%`, formatSpeedup: (value: number) => `${value}x`,
    downloadBlob: (blob: Blob) => { artifact = blob; }, showToast() {},
  };
  runInNewContext(renderer + "\n" + browserScript, context);
  elements.get("md-raw-output").value = context.buildMarkdownFromCurrentState();
  click!();
  const html = await artifact!.text();
  assert.equal((html.match(/class="windows-headline-card"/g) ?? []).length, 8);
  assert.match(html, /grid-template-columns:repeat\(4/);
  assert.match(html, /76\.4%/);
  assert.match(html, /6\.1 GB/);
  assert.match(html, /7\.3 GB/);
  assert.doesNotMatch(html, /<script/);
  fs.writeFileSync(path.resolve(process.cwd(), "build/headline-preview.html"), html);
});
