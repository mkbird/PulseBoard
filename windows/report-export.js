// This script is appended to the Windows web console after its shared script.
// Replacing the button drops the shared PNG listener while preserving its ID
// for the shared platform UI code.
(() => {
  const previous = document.getElementById("download-img-btn");
  if (!previous) return;

  const button = previous.cloneNode(true);
  previous.replaceWith(button);
  button.textContent = "⬇️ 下载 HTML";
  button.title = "下载可离线打开、可打印的 HTML 晨报";

  const reportStyle = [
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
      const body = renderGFMToHTML(markdown);
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
