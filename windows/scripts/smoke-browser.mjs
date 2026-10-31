import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// Exercises the running EXE and its actual shared + Windows scripts in Chrome.
const root = path.resolve(import.meta.dirname, "..");
const profile = fs.mkdtempSync(path.join(root, "build", "browser-smoke-"));
const chrome = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const child = spawn(chrome, ["--headless=new", "--no-first-run", `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"], { windowsHide: true, stdio: "ignore" });
let socket;
let sequence = 0;
const pending = new Map();
function command(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
try {
  const portFile = path.join(profile, "DevToolsActivePort");
  for (let i = 0; i < 100 && !fs.existsSync(portFile); i++) await wait(100);
  const port = Number(fs.readFileSync(portFile, "utf8").split("\n")[0]);
  const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket = new WebSocket(tabs.find(tab => tab.type === "page").webSocketDebuggerUrl);
  socket.addEventListener("message", event => {
    const message = JSON.parse(String(event.data));
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  });
  await new Promise((resolve, reject) => { socket.addEventListener("open", resolve); socket.addEventListener("error", reject); });
  await command("Page.enable");
  await command("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await command("Page.navigate", { url: "http://127.0.0.1:8766/" });
  for (let i = 0; i < 100; i++) {
    const state = await command("Runtime.evaluate", { expression: "typeof fetchDAGSCAnalysis === 'function' && typeof liveData !== 'undefined' && !!liveData", returnByValue: true });
    if (state.result?.value) break;
    await wait(100);
  }
  const response = await command("Runtime.evaluate", {
    expression: `(async () => {
      await fetchDAGSCAnalysis({sliceMode:'auto'});
      switchTab('report');
      const preview = document.getElementById('md-rendered-preview');
      const cards = [...preview.querySelectorAll('.windows-headline-card')];
      let exported;
      const originalDownload = downloadBlob;
      downloadBlob = (blob, filename) => { exported = {blob,filename}; };
      try {
        document.getElementById('download-img-btn').click();
        const html = await exported.blob.text();
        preview.scrollIntoView({block:'start'});
        return { cards:cards.length, labels:cards.map(card=>card.querySelector('.windows-headline-label').textContent),
          exportedCards:(html.match(/class="windows-headline-card"/g)||[]).length,
          filename:exported.filename, gpuCounters:liveData.environment.metric_capabilities.process_gpu,
          vramCounters:liveData.environment.metric_capabilities.process_vram,
          cliptoProcesses:liveData.latest.clipto_process_count };
      } finally { downloadBlob = originalDownload; }
    })()`, awaitPromise: true, returnByValue: true,
  });
  if (response.exceptionDetails) throw new Error(response.exceptionDetails.exception?.description || response.exceptionDetails.text);
  const result = response.result.value;
  assert.equal(result.cards, 8);
  assert.equal(result.exportedCards, 8);
  assert.ok(result.labels.includes("Clipto 进程组 GPU P95"));
  assert.ok(result.labels.includes("全 CMS 显存占用峰值 (VRAM)"));
  assert.ok(result.labels.includes("Clipto 显存占用峰值 (VRAM)"));
  const screenshot = await command("Page.captureScreenshot", { format: "png" });
  fs.writeFileSync(path.join(root, "build", "live-headline.png"), Buffer.from(screenshot.data, "base64"));
  console.log(JSON.stringify(result, null, 2));
} finally {
  if (socket?.readyState === WebSocket.OPEN) {
    void command("Browser.close").catch(() => {});
    await wait(300);
    socket.close();
  }
  if (child.exitCode === null) child.kill();
}
