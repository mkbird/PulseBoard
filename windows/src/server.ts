import * as http from "node:http";
import { URL } from "node:url";

import { analyzeDagsc } from "./dagsc/analyzer.js";
import type { DagscQueryOptions } from "./dagsc/types.js";
import { WindowsTelemetryService } from "./platform/telemetryService.js";
import { buildAlignedHardware } from "./report/alignment.js";
import { generateReportColumn, generateReportCSV, REPORT_CSV_LABELS } from "./report/csv.js";

type JSONMap = Record<string, any>;

export interface ServerOptions {
  telemetry: WindowsTelemetryService;
  preferredPort?: number;
  html: string;
  reportExportScript: string;
  getProfile(): JSONMap;
  updateProfile(patch: JSONMap): void;
  requestQuit(): void;
}

export interface RunningServer {
  port: number;
  url: string;
  close(): Promise<void>;
}

function json(response: http.ServerResponse, status: number, value: unknown): void {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": String(body.length),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff"
  });
  response.end(body);
}

function text(
  response: http.ServerResponse,
  status: number,
  bodyText: string,
  contentType = "text/plain; charset=utf-8",
  filename?: string
): void {
  const body = Buffer.from(bodyText, "utf8");
  const headers: Record<string, string> = {
    "Content-Type": contentType,
    "Content-Length": String(body.length),
    "X-Content-Type-Options": "nosniff"
  };
  if (filename) {
    const ascii = filename.replace(/[^\x20-\x7e]/g, "_").replaceAll('"', "_");
    headers["Content-Disposition"] = `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
  }
  response.writeHead(status, headers);
  response.end(body);
}

async function requestBody(request: http.IncomingMessage, maxBytes = 1_048_576): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const raw of request) {
    const chunk = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
    size += chunk.length;
    if (size > maxBytes) throw new Error("请求内容过大");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function intParam(url: URL, key: string): number | undefined {
  const raw = url.searchParams.get(key);
  if (raw == null || raw === "") return undefined;
  const value = Number(raw);
  return Number.isFinite(value) ? Math.trunc(value) : undefined;
}

function dagscOptions(url: URL): DagscQueryOptions {
  const gapMinutes = intParam(url, "gap_min");
  return {
    inputPath: url.searchParams.get("path") ?? "",
    sliceMode: url.searchParams.get("slice_mode") ?? "auto",
    batchID: url.searchParams.get("batch_id") || undefined,
    customFromMs: intParam(url, "from_ms"),
    customToMs: intParam(url, "to_ms"),
    batchGapMs: gapMinutes && gapMinutes >= 1 ? gapMinutes * 60_000 : undefined
  };
}

function historyPoints(value: any): JSONMap[] {
  if (Array.isArray(value)) return value;
  if (Array.isArray(value?.points)) return value.points;
  return [];
}

async function analysisWithHistory(
  telemetry: WindowsTelemetryService,
  url: URL,
  environment: JSONMap
): Promise<JSONMap> {
  const analysis = await analyzeDagsc(dagscOptions(url), environment) as JSONMap;
  const intervals = (analysis.active_intervals_ms ?? [])
    .filter((value: unknown) => Array.isArray(value) && value.length >= 2)
    .map((value: number[]) => [Number(value[0]), Number(value[1])] as [number, number]);
  const fromMs = Number(analysis.slice_start_ms ?? Date.now() - 900_000);
  const toMs = Number(analysis.slice_end_ms ?? Date.now());
  const history = await telemetry.queryHistory(fromMs, toMs, 4_000);
  analysis.aligned_hardware = buildAlignedHardware(historyPoints(history), intervals, fromMs, toMs);
  analysis.ok = true;
  return analysis;
}

async function listenOnAvailablePort(server: http.Server, preferredPort: number): Promise<number> {
  for (let port = preferredPort; port < preferredPort + 10; port += 1) {
    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (error: Error) => {
          server.off("listening", onListening);
          reject(error);
        };
        const onListening = () => {
          server.off("error", onError);
          resolve();
        };
        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(port, "127.0.0.1");
      });
      return port;
    } catch (error: any) {
      if (error?.code !== "EADDRINUSE") throw error;
    }
  }
  throw new Error(`端口 ${preferredPort}–${preferredPort + 9} 均被占用`);
}

export function prepareWindowsHTML(source: string, reportExportScript: string): string {
  if (!source.includes("</body>") || !source.includes('id="download-img-btn"')) {
    throw new Error("Web console is missing the Windows report export insertion points.");
  }
  return source
    .replaceAll("__CLIPTOPULSE_BUILD_LABEL__", "CliptoPulse Windows")
    .replace("（图片 / Markdown / CSV）", "（HTML / Markdown / CSV）")
    .replace("</body>", `<script>\n${reportExportScript}\n</script>\n</body>`);
}

export async function startServer(options: ServerOptions): Promise<RunningServer> {
  let activePort = options.preferredPort ?? 8766;
  const html = prepareWindowsHTML(options.html, options.reportExportScript);
  const server = http.createServer(async (request, response) => {
    const method = request.method ?? "GET";
    const host = request.headers.host ?? `127.0.0.1:${activePort}`;
    const url = new URL(request.url ?? "/", `http://${host}`);

    try {
      if ((url.pathname === "/" || url.pathname === "/index.html" || url.pathname === "/dagsc_analyzer.html") && method === "GET") {
        return text(response, 200, html, "text/html; charset=utf-8");
      }
      if (url.pathname === "/favicon.ico") {
        response.writeHead(204);
        return response.end();
      }
      if (url.pathname === "/api/health") {
        return json(response, 200, { ok: true, platform: "windows", pid: process.pid });
      }

      const environment = options.telemetry.getEnvironment(activePort) as JSONMap;

      if (url.pathname === "/api/bootstrap" || url.pathname === "/api/default-info") {
        return json(response, 200, {
          ok: true,
          environment,
          detected_username: environment.username ?? "",
          default_dagsc_dir: environment.default_dagsc_dir ?? ""
        });
      }

      if (url.pathname === "/api/monitor/live") {
        const live = options.telemetry.getLivePayload() as JSONMap;
        return json(response, 200, {
          ok: true,
          sampling_interval_sec: 1,
          retention_days: 120,
          enhanced_available: false,
          ...live,
          environment
        });
      }

      if (url.pathname === "/api/monitor/history") {
        const now = Date.now();
        const toMs = intParam(url, "to_ms") ?? now;
        const fromMs = intParam(url, "from_ms") ?? toMs - 900_000;
        const maxPoints = Math.max(2, Math.min(5_000, intParam(url, "max_points") ?? 600));
        const result = await options.telemetry.queryHistory(fromMs, Math.max(fromMs + 1_000, toMs), maxPoints);
        return json(response, 200, { ok: true, from_ms: fromMs, to_ms: toMs, points: historyPoints(result) });
      }

      if (url.pathname === "/api/dagsc/analyze" || url.pathname === "/api/analyze") {
        return json(response, 200, await analysisWithHistory(options.telemetry, url, environment));
      }

      if (url.pathname === "/api/report/profile") {
        if (method === "POST") {
          const raw = await requestBody(request);
          const patch = raw.length ? JSON.parse(raw.toString("utf8")) : {};
          options.updateProfile({ reporter: String(patch.reporter ?? ""), lan_host: "" });
        }
        const profile = options.getProfile();
        return json(response, 200, {
          ok: true,
          reporter: String(profile.reporter ?? ""),
          lan_host: "",
          auto_lan_host: "",
          effective_lan_host: "",
          web_port: activePort,
          detected_lan_ips: []
        });
      }

      if (url.pathname === "/api/report/csv-labels") {
        return text(response, 200, REPORT_CSV_LABELS.join("\n"));
      }

      if (url.pathname === "/api/report/csv") {
        const analysis = await analysisWithHistory(options.telemetry, url, environment);
        const reporter = String(options.getProfile().reporter ?? "");
        if (url.searchParams.get("format") === "column") {
          return text(response, 200, generateReportColumn(analysis, reporter));
        }
        const csv = generateReportCSV(analysis, reporter, url.searchParams.get("with_labels") === "1");
        const filename = `CliptoPulse-Windows-${new Date().toISOString().slice(0, 10)}.csv`;
        return text(
          response,
          200,
          csv,
          "text/csv; charset=utf-8",
          url.searchParams.get("download") === "1" ? filename : undefined
        );
      }

      if (url.pathname === "/api/export/system-csv") {
        const now = Date.now();
        const toMs = intParam(url, "to_ms") ?? now;
        const fromMs = intParam(url, "from_ms") ?? toMs - 900_000;
        const csv = await options.telemetry.exportSystemCSV(fromMs, toMs);
        return text(response, 200, csv, "text/csv; charset=utf-8", "CliptoPulse-Windows-System.csv");
      }

      if (url.pathname === "/api/export/cms-csv") {
        const now = Date.now();
        const toMs = intParam(url, "to_ms") ?? now;
        const fromMs = intParam(url, "from_ms") ?? toMs - 900_000;
        const csv = await options.telemetry.exportCMSCSV(fromMs, toMs);
        return text(response, 200, csv, "text/csv; charset=utf-8", "CliptoPulse-Windows-CMS.csv");
      }

      if (url.pathname === "/api/app/quit" && method === "POST") {
        json(response, 200, { ok: true });
        setTimeout(options.requestQuit, 50).unref();
        return;
      }

      return json(response, 404, { ok: false, error: `未找到接口：${url.pathname}` });
    } catch (error: any) {
      return json(response, url.pathname.includes("dagsc") || url.pathname.includes("report") ? 400 : 500, {
        ok: false,
        error: error?.message ?? String(error)
      });
    }
  });

  server.keepAliveTimeout = 5_000;
  activePort = await listenOnAvailablePort(server, options.preferredPort ?? 8766);
  return {
    port: activePort,
    url: `http://127.0.0.1:${activePort}`,
    close: () => new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
      server.closeIdleConnections?.();
    })
  };
}
