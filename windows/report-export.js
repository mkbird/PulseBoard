// This script is appended to the Windows web console after its shared script.
// Replacing the button drops the shared PNG listener while preserving its ID
// for the shared platform UI code.
(() => {
  const headlineStyle = `
    .windows-headline-grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:14px; margin:16px 0 24px; }
    .windows-headline-card { padding:16px; border:1px solid #dbe3ef; border-top:4px solid #4f75c2; border-radius:10px; background:#fff; min-width:0; }
    .windows-headline-label { font-size:13px; color:#475569; font-weight:600; }
    .windows-headline-value { margin:8px 0; font-size:27px; font-weight:800; color:#1d3557; overflow-wrap:anywhere; }
    .windows-headline-caption { font-size:11px; line-height:1.5; color:#64748b; overflow-wrap:anywhere; }
    @media (max-width:700px) { .windows-headline-grid { grid-template-columns:repeat(2,minmax(0,1fr)); } }
  `;

  function headlineMarkdown(data) {
    const hw = data.aligned_hardware?.has_data ? data.aligned_hardware : {};
    const scope = data.scopes?.asset_analysis || {};
    const bytes = metric => metric?.max != null ? formatBytes(metric.max) : "未采集";
    const percentile = metric => metric?.p95 != null ? formatPct(metric.p95, 1) : "未采集";
    const storage = data.aligned_hardware?.storage;
    const cells = [
      ["端到端分析速度", formatSpeedup(scope.wall_speedup), "素材总时长 ÷ 端到端处理耗时"],
      ["Clipto 进程组 CPU P95", percentile(hw.clipto_cpu_percent), "进程组合计；单核 = 100%"],
      ["Clipto 进程组 GPU P95", percentile(hw.clipto_gpu_percent), "WDDM：按同一 NVIDIA 引擎汇总，取最忙引擎；100% = 一个引擎满载"],
      ["Clipto 数据目录", storage?.end_bytes != null ? formatBytes(storage.end_bytes) : "未采集", "Clipto 数据目录磁盘占用"],
      ["全 CMS 内存占用峰值 (RAM)", bytes(hw.cms_total_memory_bytes), "CMS 进程 Working Set 合计"],
      ["全 CMS 显存占用峰值 (VRAM)", bytes(hw.cms_total_vram_bytes), "CMS 专用 GPU 内存合计"],
      ["Clipto 内存占用峰值 (RAM)", bytes(hw.clipto_memory_bytes), "Clipto 进程组 Working Set 合计（包含 CMS）"],
      ["Clipto 显存占用峰值 (VRAM)", bytes(hw.clipto_vram_bytes), "Clipto 专用 GPU 内存合计（包含 CMS）"],
    ];
    const cell = value => String(value ?? "").replace(/\|/g, "\\|").replace(/[\r\n]+/g, " ");
    return "## 🎯 头条指标\n\n| " + cells.map(item => cell(item[0])).join(" | ") + " |\n| " + cells.map(() => ":---:").join(" | ") + " |\n| " +
      cells.map(item => "**" + cell(item[1]) + "**").join(" | ") + " |\n| " + cells.map(item => cell(item[2])).join(" | ") + " |\n\n";
  }

  function renderReportHTML(markdown) {
    return renderGFMToHTML(markdown).replace(/(<h2>[^<]*头条[^<]*<\/h2>)\s*<table>([\s\S]*?)<\/table>/, (_match, heading, table) => {
      const rows = [...table.matchAll(/<tr>([\s\S]*?)<\/tr>/g)].map(row =>
        [...row[1].matchAll(/<t[hd][^>]*>([\s\S]*?)<\/t[hd]>/g)].map(cell => cell[1]));
      if (rows[0]?.length !== 8) return _match;
      return heading + '<div class="windows-headline-grid">' + rows[0].map((label, index) =>
        '<div class="windows-headline-card"><div class="windows-headline-label">' + label +
        '</div><div class="windows-headline-value">' + (rows[1]?.[index] || "未采集") +
        '</div><div class="windows-headline-caption">' + (rows[2]?.[index] || "") + '</div></div>').join("") + '</div>';
    });
  }

  // This file is served only by the Windows host; shared macOS sources stay intact.
  if (typeof buildMarkdownFromCurrentState === "function") {
    const sharedMarkdown = buildMarkdownFromCurrentState;
    buildMarkdownFromCurrentState = function () {
      let markdown = sharedMarkdown();
      if (!dagscData || dagscData.environment?.platform !== "windows") return markdown;
      markdown = markdown.replace(/## 🎯 头条指标\n[\s\S]*?(?=\n## )/, headlineMarkdown(dagscData));
      const hw = dagscData.aligned_hardware?.has_data ? dagscData.aligned_hardware : null;
      if (hw) {
        const values = metric => [metric?.avg, metric?.p95, metric?.max].map(value => value != null ? formatBytes(value) : "未采集");
        const rows = [
          ["全 CMS 显存占用 (VRAM)", hw.cms_total_vram_bytes],
          ["Clipto 进程组显存占用 (VRAM)", hw.clipto_vram_bytes],
        ].map(([label, metric]) => "| **" + label + "** | " + values(metric).join(" | ") + " | WDDM 专用 GPU 内存按进程合计；共享分配可能重复计数；共享 GPU 系统内存另计 |\n").join("");
        markdown = markdown.replace(/(\| \*\*系统物理内存[^\n]*\n)/, rows + "$1");
      }
      return markdown;
    };
    const sharedRebuild = rebuildMarkdownReport;
    rebuildMarkdownReport = function () {
      sharedRebuild();
      document.getElementById("md-rendered-preview").innerHTML = renderReportHTML(document.getElementById("md-raw-output").value);
    };
    const style = document.createElement("style");
    style.textContent = headlineStyle;
    document.head.appendChild(style);
  }

  if (typeof renderLiveMonitorCards === "function") {
    const sharedLive = renderLiveMonitorCards;
    renderLiveMonitorCards = function () {
      sharedLive();
      const sample = liveData?.latest;
      if (!sample) return;
      const value = bytes => bytes != null ? formatBytes(bytes) : "未采集";
      document.getElementById("mon-clipto-sub").textContent += " ｜ 显存(VRAM) " + value(sample.clipto_vram_bytes);
      document.getElementById("mon-cms-sub").textContent += " ｜ 显存(VRAM) " + value(sample.cms_vram_bytes);
    };
  }

  const previous = document.getElementById("download-img-btn");
  if (!previous) return;

  const button = previous.cloneNode(true);
  previous.replaceWith(button);
  button.textContent = "⬇️ 下载 HTML";
  button.title = "下载可离线打开、可打印的 HTML 晨报";

  const reportStyle = [
    headlineStyle,
    "@page { size: A4; margin: 16mm; }",
    "* { box-sizing: border-box; }",
    "html { color-scheme: light; }",
    "body { margin: 0; background: #eef2f7; color: #172033; font: 15px/1.65 -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Microsoft YaHei UI', sans-serif; }",
    ".report { max-width: 1120px; margin: 32px auto; padding: 42px 48px; background: #fff; border-radius: 16px; box-shadow: 0 8px 32px rgba(15, 23, 42, .09); }",
    "h1 { margin: 0 0 18px; padding-bottom: 12px; border-bottom: 2px solid #dbe3ef; font-size: 28px; line-height: 1.3; }",
    "h2 { margin: 32px 0 14px; color: #1d3557; font-size: 21px; break-after: avoid; }",
    "h3 { margin: 24px 0 10px; color: #334155; font-size: 17px; break-after: avoid; }",
    "p, li { overflow-wrap: anywhere; }",
    "blockquote { margin: 18px 0; padding: 12px 18px; border-left: 4px solid #4f75c2; background: #f5f8fd; color: #334155; }",
    "blockquote ul { margin: 0; padding-left: 20px; }",
    "table { width: 100%; margin: 16px 0 22px; border-collapse: collapse; table-layout: auto; font-size: 13px; }",
    "th, td { padding: 9px 10px; border: 1px solid #dbe3ef; vertical-align: top; overflow-wrap: anywhere; }",
    "th { background: #edf3fb; color: #243b5a; font-weight: 700; }",
    "tbody tr:nth-child(even) { background: #f8fafc; }",
    "code { padding: 1px 4px; border-radius: 4px; background: #edf2f8; font: .92em Consolas, 'Cascadia Code', monospace; overflow-wrap: anywhere; }",
    "strong { color: #162a47; }",
    "thead { display: table-header-group; }",
    "tr, blockquote { break-inside: avoid; }",
    "@media (max-width: 700px) { .report { margin: 0; padding: 20px 16px; border-radius: 0; box-shadow: none; } table { font-size: 12px; } th, td { padding: 6px; } }",
    "@media print { body { background: #fff; print-color-adjust: exact; -webkit-print-color-adjust: exact; } .report { max-width: none; margin: 0; padding: 0; border-radius: 0; box-shadow: none; } }"
  ].join("\n");

  function escapeHTML(value) {
    return value.replace(/[&<>"']/g, character => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"
    })[character]);
  }

  button.addEventListener("click", () => {
    try {
      const markdown = document.getElementById("md-raw-output")?.value || "";
      if (!markdown.trim()) throw new Error("请先加载晨报数据");
      const badge = document.getElementById("rpt-filename-badge")?.textContent || "Clipto离线分析晨报.md";
      const filename = badge.replace(/\.(md|png|html)$/i, "") + ".html";
      const title = escapeHTML(filename.replace(/\.html$/i, ""));
      const body = renderReportHTML(markdown);
      const html = "<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n" +
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" +
        "<title>" + title + "</title>\n<style>\n" + reportStyle + "\n</style>\n</head>\n" +
        "<body>\n<main class=\"report\">\n" + body + "\n</main>\n</body>\n</html>\n";
      downloadBlob(new Blob([html], { type: "text/html;charset=utf-8" }), filename);
      showToast("✓ 已下载 " + filename);
    } catch (error) {
      showToast("✗ " + (error?.message || error));
    }
  });
})();
