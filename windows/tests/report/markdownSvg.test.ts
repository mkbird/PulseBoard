import assert from "node:assert/strict";
import test from "node:test";

import { renderMarkdownReportSVG } from "../../src/report/markdownSvg.ts";

const SAMPLE = `# Clipto Windows 离线分析性能晨报

> - **运行时段**：2026-10-27 10:00 ~ 10:15
> - **测试平台**：RTX 5080 & Windows <11>

## 🎯 头条指标

| 端到端分析速度 | 全 CMS Working Set 峰值 (RAM) | NVIDIA GPU 显存峰值 (VRAM) |
| :---: | :---: | :---: |
| **2.5x** | **8.2 GB** | **11.2 GB / 16 GB** |
| 越大越快 | WorkingSet64（RAM，不含 VRAM） | nvidia-smi memory.used / total |

## 一、吞吐概览

普通段落包含 \`code\` 与 **粗体**，以及转义竖线 A\\|B。

- 第一项
- 第二项

1. 有序第一项
2. 有序第二项`;

test("renders the morning-report Markdown subset as standalone escaped SVG", () => {
  const result = renderMarkdownReportSVG(SAMPLE);
  assert.equal(result.width, 1_180);
  assert.equal(result.height > 500, true);
  assert.match(result.svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(result.svg, /<linearGradient/);
  assert.match(result.svg, /Clipto Windows 离线分析性能晨报/);
  assert.match(result.svg, /RTX 5080 &amp; Windows &lt;11&gt;/);
  assert.match(result.svg, /A\|B/);
  assert.doesNotMatch(result.svg, /\*\*2\.5x\*\*/);
  assert.doesNotMatch(result.svg, /<11>/);
  assert.doesNotMatch(result.svg, /NaN|Infinity/);
});

test("wraps long Chinese text and stays within the configured safe height", () => {
  const short = renderMarkdownReportSVG("# 标题\n\n## 小节\n\n简短内容", { width: 900 });
  const long = renderMarkdownReportSVG(`# 标题\n\n## 小节\n\n${"这是一段需要自动换行的中文内容。".repeat(180)}`, {
    width: 900,
  });
  const capped = renderMarkdownReportSVG(`# 标题\n\n${("## 小节\n\n" + "非常长的内容".repeat(200) + "\n\n").repeat(50)}`, {
    width: 900,
    maxHeight: 1_000,
  });

  assert.equal(long.height > short.height, true);
  assert.equal(capped.height <= 1_000, true);
  assert.match(capped.svg, /图片已在安全高度处截断/);
});

test("renders escaped pipes as one table cell value", () => {
  const result = renderMarkdownReportSVG([
    "# 表格",
    "",
    "| 名称 | 说明 |",
    "| :--- | ---: |",
    "| A\\|B | 安全 & 稳定 |",
  ].join("\n"));

  assert.match(result.svg, /A\|B/);
  assert.match(result.svg, /安全 &amp; 稳定/);
});
