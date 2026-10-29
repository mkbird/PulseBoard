import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

const windowsRoot = path.dirname(fileURLToPath(import.meta.url));
const testsRoot = path.join(windowsRoot, "tests");
const outputRoot = path.join(windowsRoot, "build", "tests");

function collectFiles(directory, suffix) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const candidate = path.join(directory, entry.name);
    if (entry.isDirectory()) return collectFiles(candidate, suffix);
    return entry.isFile() && entry.name.endsWith(suffix) ? [candidate] : [];
  });
}

const entryPoints = collectFiles(testsRoot, ".test.ts");
if (entryPoints.length === 0) throw new Error("No Windows tests were found.");
fs.rmSync(outputRoot, { recursive: true, force: true });

await build({
  absWorkingDir: windowsRoot,
  entryPoints,
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node24",
  outdir: outputRoot,
  outbase: testsRoot,
  outExtension: { ".js": ".cjs" },
  logLevel: "info",
});

const bundles = collectFiles(outputRoot, ".test.cjs");
const result = spawnSync(process.execPath, ["--test", ...bundles], { stdio: "inherit" });
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
