//
//  SQLiteBinStore.swift
//  WXYCAPI
//
//  Raw-SQLite (import SQLite3) implementation of BinStore for the on-device bin
//  snapshot (issue #60). Mirrors SQLiteCatalogStore: rows are JSONCoders-encoded
//  BinEntry BLOBs keyed by BinEntry.id, a meta row marks "snapshot present" so a
//  written-but-empty bin ([]) is distinguishable from never-written (nil), and a
//  saveSnapshot replaces the whole bin in a single rolled-back-on-error
//  transaction. Its own DB + actor, deliberately separate from the catalog clone
//  so a bin read never queues behind a multi-second catalog replace.
//
//  Created by Jake on 06/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import SQLite3

/// Errors surfaced by ``SQLiteBinStore``. Carry the SQLite diagnostic so a failed
/// snapshot save is debuggable.
public enum BinStoreError: Error, Sendable {
    /// `sqlite3_open_v2` failed (path unwritable, corruption, etc.).
    case open(String)
    /// A statement (prepare/bind/step/exec) failed; the string is the context
    /// plus `sqlite3_errmsg`.
    case sqlite(String)
}

/// An id-keyed SQLite-backed clone of the DJ's last server bin snapshot. The C
/// handle (`OpaquePointer`, not `Sendable`) is isolated to this `actor`, which
/// also serializes every access; combined with libsqlite3's serialized threading
/// mode, that keeps the connection race-free while satisfying ``BinStore``'s
/// `Sendable` requirement.
public actor SQLiteBinStore: BinStore {
    /// Key in `meta` whose presence records that a snapshot was written (even an
    /// empty one), so ``snapshot()`` can return `[]` vs `nil`.
    private static let snapshotPresentKey = "snapshot_present"

    /// Owns the raw connection and closes it on dealloc. A plain reference type
    /// (not the actor itself) so its `deinit` may touch the non-Sendable handle
    /// — an actor's nonisolated `deinit` cannot. All *use* of the handle stays
    /// serialized by the enclosing actor; `deinit` runs only once no task holds
    /// the actor, so no statement is ever in flight at close.
    private final class Connection {
        let db: OpaquePointer
        init(db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close(db) }
    }

    private let connection: Connection
    private var db: OpaquePointer { connection.db }

    /// Open (creating if needed) the bin database at `url` and ensure the schema
    /// exists. Throws ``BinStoreError/open(_:)`` if the file can't be opened.
    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (rc=\(rc))"
            if let handle { sqlite3_close(handle) }
            throw BinStoreError.open(message)
        }
        do {
            try Self.exec(handle, "CREATE TABLE IF NOT EXISTS bin (id INTEGER PRIMARY KEY, row BLOB NOT NULL);")
            // value is NOT NULL because the store only ever writes a present
            // marker ('1'); its presence/absence is the snapshot-present signal.
            try Self.exec(handle, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        } catch {
            sqlite3_close(handle)
            throw error
        }
        self.connection = Connection(db: handle)
    }

    // MARK: BinStore

    public func snapshot() throws -> [BinEntry]? {
        // No marker -> never written. Distinct from a written empty bin, which
        // has the marker but no rows (returns []).
        guard try Self.snapshotPresent(db) else { return nil }
        let stmt = try Self.prepare(db, "SELECT row FROM bin;")
        defer { sqlite3_finalize(stmt) }
        var entries: [BinEntry] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                if let entry = try Self.decodeEntry(stmt) { entries.append(entry) }
            case SQLITE_DONE:
                return entries
            default:
                throw Self.error(db, "step snapshot")
            }
        }
    }

    public func saveSnapshot(_ entries: [BinEntry]) throws {
        // Bind the handle to a local so the `withUnsafeBytes` closure below
        // captures it from this method's isolation region, rather than reaching
        // through actor-isolated `self.db` (which trips region-based sendability
        // analysis on the non-Sendable statement pointer).
        let db = connection.db
        try Self.exec(db, "BEGIN IMMEDIATE;")
        do {
            try Self.exec(db, "DELETE FROM bin;")
            let stmt = try Self.prepare(db, "INSERT INTO bin (id, row) VALUES (?, ?);")
            defer { sqlite3_finalize(stmt) }
            for entry in entries {
                let blob = try JSONCoders.encoder.encode(entry)
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard sqlite3_bind_int64(stmt, 1, Int64(entry.id)) == SQLITE_OK else {
                    throw Self.error(db, "bind id")
                }
                try blob.withUnsafeBytes { raw in
                    guard sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), Self.transientDestructor) == SQLITE_OK else {
                        throw Self.error(db, "bind row")
                    }
                }
                // Plain INSERT (not OR REPLACE): a duplicate id raises
                // SQLITE_CONSTRAINT, which fails the whole save and rolls back —
                // keeping the last-good snapshot, the same fail-closed posture as
                // the catalog store.
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw Self.error(db, "insert id \(entry.id)")
                }
            }
            // Set the present marker *inside* the transaction so a written-empty
            // bin commits the marker atomically with the (empty) row set.
            try Self.setSnapshotPresent(db)
            try Self.exec(db, "COMMIT;")
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
    }

    // MARK: Private SQLite helpers

    /// `SQLITE_TRANSIENT` — tells SQLite to copy the bound bytes, so the Swift
    /// `Data`/`String` can be freed when the bind call returns. Not exported by
    /// the SQLite3 module overlay, so it's reconstructed here. A C function
    /// pointer is `Sendable`, so this is a plain `static let` constant.
    private static let transientDestructor: sqlite3_destructor_type =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw error(db, "prepare \(sql.prefix(40))")
        }
        return stmt
    }

    private static func decodeEntry(_ stmt: OpaquePointer) throws -> BinEntry? {
        guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        let data = Data(bytes: bytes, count: count)
        return try JSONCoders.decoder.decode(BinEntry.self, from: data)
    }

    private static func snapshotPresent(_ db: OpaquePointer) throws -> Bool {
        let stmt = try prepare(db, "SELECT value FROM meta WHERE key = '\(snapshotPresentKey)';")
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(db, "step snapshot marker")
        }
    }

    private static func setSnapshotPresent(_ db: OpaquePointer) throws {
        try exec(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('\(snapshotPresentKey)', '1');")
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw BinStoreError.sqlite("exec '\(sql.prefix(40))': \(message)")
        }
    }

    private static func error(_ db: OpaquePointer, _ context: String) -> BinStoreError {
        .sqlite("\(context): \(String(cString: sqlite3_errmsg(db)))")
    }
}
