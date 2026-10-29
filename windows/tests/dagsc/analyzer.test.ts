import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import { analyzeDagsc } from "../../src/dagsc/analyzer.ts";

test("DAGSC analysis reads committed WAL frames and preserves batch slicing", async () => {
  const directory = mkdtempSync(join(tmpdir(), "cliptopulse-win-dagsc-test-"));
  const databasePath = join(directory, "schedule.db");
  const db = new DatabaseSync(databasePath);
  try {
    db.exec(`
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      CREATE TABLE v_workflows(
        workflow_id TEXT, template_id TEXT, template_version TEXT, asset_id TEXT,
        status_text TEXT, created_at INTEGER, started_at INTEGER, finished_at INTEGER,
        analysis_mode TEXT, asset_metadata TEXT, context_json TEXT
      );
      CREATE TABLE workflows(workflow_id TEXT, template_id TEXT, asset_id TEXT);
      CREATE TABLE nodes(workflow_id TEXT, node_id TEXT, template_node_id TEXT);
      CREATE TABLE v_tasks(
        task_id TEXT, workflow_id TEXT, node_id TEXT, node_type TEXT, status_text TEXT,
        executor_text TEXT, dispatched_at INTEGER, started_at INTEGER, finished_at INTEGER,
        error_json TEXT
      );
      CREATE TABLE workflow_templates(template_id TEXT, template_version TEXT, loaded_at INTEGER);
      INSERT INTO workflow_templates VALUES ('clipto_asset_analysis', 'test-1', 1);
    `);

    const base = 1_800_000_000_000;
    const insertWorkflow = db.prepare(`
      INSERT INTO v_workflows VALUES (?, 'clipto_asset_analysis', 'test-1', ?, 'succeeded', ?, ?, ?,
        'default', ?, ?)
    `);
    const insertWorkflowJoin = db.prepare("INSERT INTO workflows VALUES (?, 'clipto_asset_analysis', ?)");
    const insertNode = db.prepare("INSERT INTO nodes VALUES (?, 'node-1', 'decode')");
    const insertTask = db.prepare(`
      INSERT INTO v_tasks VALUES (?, ?, 'node-1', 'decode', 'succeeded', 'cpu', ?, ?, ?, '')
    `);
    const starts = [base, base + 20 * 60_000];
    for (let index = 0; index < starts.length; index += 1) {
      const workflowID = `wf-${index + 1}`;
      const assetID = String(index + 1);
      const start = starts[index];
      const end = start + 10_000;
      insertWorkflow.run(
        workflowID,
        assetID,
        start,
        start,
        end,
        JSON.stringify({ filename: `asset-${index + 1}.mp4` }),
        JSON.stringify({ duration: 60_000, file_size_bytes: 1_000, asset_type: "video" }),
      );
      insertWorkflowJoin.run(workflowID, assetID);
      insertNode.run(workflowID);
      insertTask.run(`task-${index + 1}`, workflowID, start, start, end);
    }

    const result = await analyzeDagsc({ inputPath: databasePath, sliceMode: "all" }, { platform: "windows" });
    assert.equal(result.ok, true);
    assert.equal(result.assets_total, 2);
    assert.equal((result.available_batches as unknown[]).length, 2);
    const scope = (result.scopes as { asset_analysis: Record<string, unknown> }).asset_analysis;
    assert.equal(scope.total_tasks, 2);
    assert.equal(scope.wall_clock_ms, 20_000);
    assert.equal(scope.wall_speedup, 6);

    const latestBatch = (result.available_batches as Array<{ batch_id: string }>)[0];
    const latest = await analyzeDagsc({ inputPath: databasePath, sliceMode: "batch", batchID: latestBatch.batch_id }, {});
    assert.equal(latest.slice_mode, "batch");
    assert.equal(latest.assets_total, 1);
  } finally {
    db.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
