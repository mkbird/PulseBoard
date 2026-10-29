import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as sea from "node:sea";

interface WindowsTrayOptions {
  openURL: string;
  quitURL: string;
  iconPNG?: Uint8Array;
  tooltip?: string;
  onExit?: (code: number | null) => void;
}

export interface WindowsTrayHandle {
  readonly child: ChildProcess;
  stop(): Promise<void>;
}

function psLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function trayScript(options: WindowsTrayOptions, iconPath: string | undefined): string {
  const iconSetup = iconPath
    ? `
$bitmap = [System.Drawing.Bitmap]::FromFile(${psLiteral(iconPath)})
$iconHandle = $bitmap.GetHicon()
$tray.Icon = [System.Drawing.Icon]::FromHandle($iconHandle)
`
    : "$tray.Icon = [System.Drawing.SystemIcons]::Application\n";

  return `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$tray = New-Object System.Windows.Forms.NotifyIcon
${iconSetup}
$tray.Text = ${psLiteral(options.tooltip ?? "CliptoPulse")}
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add('打开 CliptoPulse')
$openAction = {
  Start-Process ${psLiteral(options.openURL)}
}
$openItem.add_Click($openAction)
$tray.add_DoubleClick($openAction)
$exitItem = $menu.Items.Add('退出')
$exitItem.add_Click({
  try {
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri ${psLiteral(options.quitURL)} -TimeoutSec 2 | Out-Null
  } catch {
  }
  $tray.Visible = $false
  $tray.Dispose()
  [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu
[System.Windows.Forms.Application]::Run()
`;
}

function writeTrayIcon(bytes: Uint8Array): string {
  const localAppData = process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local");
  const runtimeDirectory = path.join(localAppData, "CliptoPulse", "runtime");
  fs.mkdirSync(runtimeDirectory, { recursive: true });
  const iconPath = path.join(runtimeDirectory, "tray-icon.png");
  fs.writeFileSync(iconPath, bytes);
  return iconPath;
}

function bundledIconPNG(): Uint8Array | undefined {
  if (!sea.isSea()) return undefined;
  try {
    return new Uint8Array(sea.getRawAsset("app_icon.png"));
  } catch {
    return undefined;
  }
}

function spawnWindowsTray(options: WindowsTrayOptions): WindowsTrayHandle | undefined {
  if (process.platform !== "win32") return undefined;
  const iconPath = options.iconPNG ? writeTrayIcon(options.iconPNG) : undefined;
  const source = trayScript(options, iconPath);
  const encoded = Buffer.from(source, "utf16le").toString("base64");
  const child = spawn(
    "powershell.exe",
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
    {
      windowsHide: true,
      stdio: "ignore"
    }
  );
  let stopping = false;
  child.once("exit", (code) => {
    if (!stopping) options.onExit?.(code);
  });
  child.unref();
  return {
    child,
    stop: async () => {
      if (child.exitCode !== null || child.killed) return;
      stopping = true;
      await new Promise<void>((resolve) => {
        const timeout = setTimeout(resolve, 1_000);
        child.once("exit", () => {
          clearTimeout(timeout);
          resolve();
        });
        child.kill();
      });
    }
  };
}

export async function startWindowsTray(
  baseURL: string,
  onExit: () => void
): Promise<WindowsTrayHandle | undefined> {
  const normalizedBaseURL = baseURL.replace(/\/+$/, "");
  return spawnWindowsTray({
    openURL: normalizedBaseURL,
    quitURL: `${normalizedBaseURL}/api/app/quit`,
    iconPNG: bundledIconPNG(),
    tooltip: "CliptoPulse",
    onExit
  });
}
