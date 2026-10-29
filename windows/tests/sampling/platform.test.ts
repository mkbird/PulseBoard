import assert from "node:assert/strict";
import test from "node:test";

import { isCMSProcessName } from "../../src/platform/processSampler.js";
import { discoverWindowsCliptoPaths } from "../../src/platform/windowsEnvironment.js";

test("CMS process classification matches Clipto worker naming", () => {
  assert.equal(isCMSProcessName("cms_vlm_worker"), true);
  assert.equal(isCMSProcessName("CMS-ASR"), true);
  assert.equal(isCMSProcessName("cbs-worker"), false);
  assert.equal(isCMSProcessName("CliptoPulse"), false);
});

test("Windows Clipto paths are derived from LOCALAPPDATA", () => {
  const paths = discoverWindowsCliptoPaths(
    {
      LOCALAPPDATA: "C:\\Users\\tester\\AppData\\Local",
      ProgramFiles: "C:\\Program Files",
      "ProgramFiles(x86)": "C:\\Program Files (x86)",
    },
    () => false,
  );
  assert.equal(
    paths.scheduleDatabasePath,
    "C:\\Users\\tester\\AppData\\Local\\Clipto\\dagsc_data\\data\\schedule.db",
  );
  assert.equal(
    paths.executablePath,
    "C:\\Users\\tester\\AppData\\Local\\Programs\\Clipto\\Clipto.exe",
  );
});
