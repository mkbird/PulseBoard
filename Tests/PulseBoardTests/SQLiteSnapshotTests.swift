import Foundation
import SQLite3
import Testing
@testable import PulseBoard

private enum SQLiteSnapshotTestError: Error {
    case sqlite(String)
}

@Test func sqliteSnapshotIncludesCommittedWALFrames() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cliptopulse_snapshot_test_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.sqlite")
    let snapshotURL = directory.appendingPathComponent("snapshot.sqlite")

    var sourceHandle: OpaquePointer?
    guard sqlite3_open(sourceURL.path, &sourceHandle) == SQLITE_OK, let source = sourceHandle else {
        throw SQLiteSnapshotTestError.sqlite("Could not open source database")
    }
    defer { sqlite3_close(source) }

    try execute("PRAGMA journal_mode=WAL;", on: source)
    try execute("PRAGMA wal_autocheckpoint=0;", on: source)
    try execute("CREATE TABLE samples(id INTEGER PRIMARY KEY, value TEXT NOT NULL);", on: source)
    try execute("INSERT INTO samples(value) VALUES ('first'), ('second');", on: source)

    try SQLiteSnapshot.create(from: sourceURL, at: snapshotURL)

    var snapshotHandle: OpaquePointer?
    guard sqlite3_open_v2(snapshotURL.path, &snapshotHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let snapshot = snapshotHandle else {
        throw SQLiteSnapshotTestError.sqlite("Could not open snapshot database")
    }
    defer { sqlite3_close(snapshot) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(snapshot, "SELECT COUNT(*) FROM samples;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteSnapshotTestError.sqlite(String(cString: sqlite3_errmsg(snapshot)))
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteSnapshotTestError.sqlite(String(cString: sqlite3_errmsg(snapshot)))
    }
    #expect(sqlite3_column_int(statement, 0) == 2)
}

private func execute(_ sql: String, on database: OpaquePointer) throws {
    var error: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(database, sql, nil, nil, &error)
    defer { sqlite3_free(error) }
    guard status == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        throw SQLiteSnapshotTestError.sqlite(message)
    }
}
