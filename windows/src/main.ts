import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { getAsset, isSea } from "node:sea";

import { WindowsTelemetryService } from "./platform/telemetryService.js";
import { startServer, type RunningServer } from "./server.js";
import { acquireSingleInstance, type SingleInstanceHandle } from "./singleInstance.js";
import { startWindowsTray, type WindowsTrayHandle } from "./tray.js";

type JSONMap = Record<string, any>;

const localAppData = process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local");
const appDirectory = path.join(localAppData, "CliptoPulse");
const logDirectory = path.join(appDirectory, "logs");
const logPath = path.join(logDirectory, "cliptopulse.log");
const profilePath = path.join(appDirectory, "profile.json");

fs.mkdirSync(logDirectory, { recursive: true });

function log(message: string, error?: unknown): void {
  const detail = error instanceof Error ? `${error.stack ?? error.message}` : error == null ? "" : String(error);
  const line = `[${new Date().toISOString()}] ${message}${detail ? `\n${detail}` : ""}\n`;
  try { fs.appendFileSync(logPath, line, "utf8"); } catch { /* best effort */ }
  try { process.stderr.write(line); } catch { /* Windows subsystem build has no console */ }
}

function loadProfile(): JSONMap {
  try {
    return JSON.parse(fs.readFileSync(profilePath, "utf8"));
  } catch {
    return { reporter: "", lan_host: "" };
  }
}

let profile = loadProfile();

function updateProfile(patch: JSONMap): void {
  profile = { ...profile, ...patch, lan_host: "" };
  fs.mkdirSync(appDirectory, { recursive: true });
  fs.writeFileSync(profilePath, JSON.stringify(profile, null, 2), "utf8");
}

function repositoryHTMLPath(): string | undefined {
  const candidates = [
    path.resolve(__dirname, "../../Sources/PulseBoard/Resources/web_console.html"),
    path.resolve(process.cwd(), "Sources/PulseBoard/Resources/web_console.html"),
    path.resolve(path.dirname(process.execPath), "../Sources/PulseBoard/Resources/web_console.html")
  ];
  return candidates.find(candidate => fs.existsSync(candidate));
}

function loadHTML(): string {
  if (isSea()) return getAsset("web_console.html", "utf8") as string;
  const source = repositoryHTMLPath();
  if (!source) throw new Error("找不到 web_console.html；请从仓库根目录运行开发版本。");
  return fs.readFileSync(source, "utf8");
}

function loadReportExportScript(): string {
  if (isSea()) return getAsset("report_export.js", "utf8") as string;
  return fs.readFileSync(path.resolve(__dirname, "../report-export.js"), "utf8");
}

function openBrowser(url: string): void {
  try {
    const child = spawn("rundll32.exe", ["url.dll,FileProtocolHandler", url], {
      windowsHide: true,
      detached: true,
      stdio: "ignore"
    });
    child.unref();
  } catch (error) {
    log(`Unable to open browser at ${url}`, error);
  }
}

function showFatal(message: string): void {
  log("Fatal startup error", message);
  if (process.platform !== "win32") return;
  const escaped = message.replaceAll("'", "''");
  const source = `Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('${escaped}', 'CliptoPulse', 'OK', 'Error') | Out-Null`;
  const encoded = Buffer.from(source, "utf16le").toString("base64");
  try {
    spawn("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], {
      windowsHide: true,
      detached: true,
      stdio: "ignore"
    }).unref();
  } catch { /* log already written */ }
}

let instance: SingleInstanceHandle | undefined;
let telemetry: WindowsTelemetryService | undefined;
let server: RunningServer | undefined;
let tray: WindowsTrayHandle | undefined;
let currentURL = "";
let activateWhenReady = false;
let quitting = false;

async function shutdown(exitCode = 0): Promise<void> {
  if (quitting) return;
  quitting = true;
  log("Stopping CliptoPulse");
  try { if (tray) await tray.stop(); } catch (error) { log("Tray shutdown failed", error); }
  try { if (server) await server.close(); } catch (error) { log("HTTP server shutdown failed", error); }
  try { if (telemetry) await telemetry.stop(); } catch (error) { log("Telemetry shutdown failed", error); }
  try { if (instance) await instance.close(); } catch (error) { log("Single-instance shutdown failed", error); }
  process.exit(exitCode);
}

async function main(): Promise<void> {
  if (process.platform !== "win32") throw new Error("Windows host can only run on Windows.");
  log(`Starting CliptoPulse ${isSea() ? "portable EXE" : "development host"}; Node ${process.version}`);

  instance = await acquireSingleInstance(
    () => {
      if (currentURL) openBrowser(currentURL);
      else activateWhenReady = true;
    },
    { name: "CliptoPulse-Windows-v1" }
  );
  if (!instance.primary) return;

  telemetry = new WindowsTelemetryService({ appDataDirectory: appDirectory });
  await telemetry.start();

  server = await startServer({
    telemetry,
    preferredPort: 8766,
    html: loadHTML(),
    reportExportScript: loadReportExportScript(),
    getProfile: () => ({ ...profile }),
    updateProfile,
    requestQuit: () => { void shutdown(0); }
  });
  currentURL = server.url;
  tray = await startWindowsTray(server.url, () => {
    if (!quitting) log("Tray helper exited unexpectedly");
  });

  log(`Ready at ${server.url}; history=${telemetry.historyPath}`);
  openBrowser(server.url);
  if (activateWhenReady) openBrowser(server.url);
}

process.on("SIGINT", () => { void shutdown(0); });
process.on("SIGTERM", () => { void shutdown(0); });
process.on("uncaughtException", error => {
  log("Uncaught exception", error);
  showFatal(error.message);
  void shutdown(1);
});
process.on("unhandledRejection", error => {
  log("Unhandled rejection", error);
});

void main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  showFatal(message);
  void shutdown(1);
});
