import Foundation
import SQLite3

/// Produces a transactionally consistent, standalone copy of an SQLite database.
///
/// The source is opened read-only and copied through SQLite's online-backup API.
/// This includes committed WAL frames without racing separate copies of the main,
/// `-wal`, and `-shm` files.
enum SQLiteSnapshot {
    private static let busyRetryLimit = 40
    private static let busyRetryDelayMilliseconds: Int32 = 50

    static func create(from sourceURL: URL, at destinationURL: URL) throws {
        var sourceHandle: OpaquePointer?
        let sourceStatus = sqlite3_open_v2(
            sourceURL.path,
            &sourceHandle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceStatus == SQLITE_OK, let source = sourceHandle else {
            let message = errorMessage(handle: sourceHandle, fallbackCode: sourceStatus)
            if let sourceHandle { sqlite3_close(sourceHandle) }
            throw DAGSCError.sqliteOpenFailed("source snapshot open failed: \(message)")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 2_000)

        var destinationHandle: OpaquePointer?
        let destinationStatus = sqlite3_open_v2(
            destinationURL.path,
            &destinationHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationStatus == SQLITE_OK, let destination = destinationHandle else {
            let message = errorMessage(handle: destinationHandle, fallbackCode: destinationStatus)
            if let destinationHandle { sqlite3_close(destinationHandle) }
            throw DAGSCError.sqliteOpenFailed("snapshot destination open failed: \(message)")
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 2_000)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DAGSCError.sqliteQueryFailed(
                "snapshot initialization failed: \(String(cString: sqlite3_errmsg(destination)))"
            )
        }

        var stepStatus: Int32 = SQLITE_OK
        var busyRetries = 0
        repeat {
            stepStatus = sqlite3_backup_step(backup, -1)
            if stepStatus == SQLITE_BUSY || stepStatus == SQLITE_LOCKED {
                busyRetries += 1
                if busyRetries <= busyRetryLimit {
                    sqlite3_sleep(busyRetryDelayMilliseconds)
                }
            }
        } while stepStatus == SQLITE_OK ||
                    ((stepStatus == SQLITE_BUSY || stepStatus == SQLITE_LOCKED) && busyRetries <= busyRetryLimit)

        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            let status = stepStatus == SQLITE_DONE ? finishStatus : stepStatus
            throw DAGSCError.sqliteQueryFailed(
                "snapshot failed (SQLite \(status)): \(String(cString: sqlite3_errmsg(destination)))"
            )
        }
    }

    private static func errorMessage(handle: OpaquePointer?, fallbackCode: Int32) -> String {
        if let handle { return String(cString: sqlite3_errmsg(handle)) }
        return String(cString: sqlite3_errstr(fallbackCode))
    }
}
