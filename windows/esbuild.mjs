import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const windowsRoot = path.dirname(fileURLToPath(import.meta.url));

await build({
  absWorkingDir: windowsRoot,
  entryPoints: ["./src/main.ts"],
  outfile: "build/main.cjs",
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node24",
  packages: "bundle",
  sourcemap: false,
  minify: false,
  legalComments: "none",
  logLevel: "info"
});
