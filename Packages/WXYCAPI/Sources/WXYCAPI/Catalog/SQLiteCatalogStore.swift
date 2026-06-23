//
//  SQLiteCatalogStore.swift
//  WXYCAPI
//
//  Raw-SQLite (import SQLite3) implementation of CatalogStore for the on-device
//  catalog clone (issue #19 step 2). Rows are stored as JSONCoders-encoded
//  CatalogRow BLOBs keyed by album id (O(1) deep-link lookup), the watermark in
//  a meta row, and a 200 replaces the whole catalog in a single rolled-back-on-
//  error transaction. SwiftData/Core Data are deliberately avoided for this
//  read-mostly, wholesale-replaced cache (ADR-0005).
//
//  Created by Jake on 06/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import SQLite3

/// Errors surfaced by ``SQLiteCatalogStore``. Carry the SQLite diagnostic so a
/// failed clone replace is debuggable.
public enum CatalogStoreError: Error, Sendable {
    /// `sqlite3_open_v2` failed (path unwritable, corruption, etc.).
    case open(String)
    /// A statement (prepare/bind/step/exec) failed; the string is the context
    /// plus `sqlite3_errmsg`.
    case sqlite(String)
}

/// An id-keyed SQLite-backed catalog clone. The C handle (`OpaquePointer`, not
/// `Sendable`) is isolated to this `actor`, which also serializes every access;
/// combined with libsqlite3's serialized threading mode, that keeps the
/// connection race-free while satisfying the `Sendable` requirement the shared
/// `CatalogRefreshService` (step 4) imposes.
public actor SQLiteCatalogStore: CatalogStore {
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

    /// Open (creating if needed) the catalog database at `url` and ensure the
    /// schema exists. Throws ``CatalogStoreError/open(_:)`` if the file can't be
    /// opened.
    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (rc=\(rc))"
            if let handle { sqlite3_close(handle) }
            throw CatalogStoreError.open(message)
        }
        do {
            try Self.exec(handle, "CREATE TABLE IF NOT EXISTS catalog (id INTEGER PRIMARY KEY, row BLOB NOT NULL);")
            // value is NOT NULL because the store never writes a NULL watermark:
            // setWatermark inserts a present non-null string or DELETEs the row.
            // (lastModified() still tolerates a NULL column defensively.)
            try Self.exec(handle, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        } catch {
            sqlite3_close(handle)
            throw error
        }
        self.connection = Connection(db: handle)
    }

    // MARK: CatalogStore

    public func row(id: Int) throws -> CatalogRow? {
        let stmt = try Self.prepare(db, "SELECT row FROM catalog WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, Int64(id)) == SQLITE_OK else { throw Self.error(db, "bind id") }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return try Self.decodeRow(stmt)
        case SQLITE_DONE: return nil
        default: throw Self.error(db, "step select")
        }
    }

    public func count() throws -> Int {
        let stmt = try Self.prepare(db, "SELECT COUNT(*) FROM catalog;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Self.error(db, "step count") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func ids() throws -> Set<Int> {
        // SELECT the primary key only — never the row BLOB — so the step-4 diff
        // stays cheap on a tens-of-thousands-row catalog.
        let stmt = try Self.prepare(db, "SELECT id FROM catalog;")
        defer { sqlite3_finalize(stmt) }
        var ids: Set<Int> = []
        loop: while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                ids.insert(Int(sqlite3_column_int64(stmt, 0)))
            case SQLITE_DONE:
                break loop
            default:
                throw Self.error(db, "step ids")
            }
        }
        return ids
    }

    public func lastModified() throws -> String? {
        let stmt = try Self.prepare(db, "SELECT value FROM meta WHERE key = 'last_modified';")
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: text)
        case SQLITE_DONE:
            return nil
        default:
            throw Self.error(db, "step watermark read")
        }
    }

    public func rows(after id: Int?, limit: Int) throws -> [CatalogRow] {
        guard limit > 0 else { return [] }
        let stmt = try Self.prepare(db, "SELECT row FROM catalog WHERE id > ? ORDER BY id LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        // Album ids are positive, so `Int64.min` as the nil-cursor sentinel makes
        // `id > ?` match every row from the start. `limit` is bound as int64 so a
        // caller can't overflow Int32.
        guard sqlite3_bind_int64(stmt, 1, id.map(Int64.init) ?? Int64.min) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, Int64(limit)) == SQLITE_OK else {
            throw Self.error(db, "bind page")
        }
        var page: [CatalogRow] = []
        loop: while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                // A corrupt blob throws and fails the page — same fail-closed
                // posture as `replace`/the NDJSON parser: a torn read never
                // yields a silently-truncated index.
                if let row = try Self.decodeRow(stmt) { page.append(row) }
            case SQLITE_DONE:
                break loop
            default:
                throw Self.error(db, "step page")
            }
        }
        return page
    }

    public func replace(rows: [CatalogRow], lastModified: String?) throws {
        // Bind the handle to a local so the `withUnsafeBytes` closure below
        // captures it from this method's isolation region, rather than reaching
        // through actor-isolated `self.db` (which trips region-based sendability
        // analysis on the non-Sendable statement pointer).
        let db = connection.db
        try Self.exec(db, "BEGIN IMMEDIATE;")
        do {
            try Self.exec(db, "DELETE FROM catalog;")
            let stmt = try Self.prepare(db, "INSERT INTO catalog (id, row) VALUES (?, ?);")
            defer { sqlite3_finalize(stmt) }
            for row in rows {
                let blob = try JSONCoders.encoder.encode(row)
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard sqlite3_bind_int64(stmt, 1, Int64(row.id)) == SQLITE_OK else {
                    throw Self.error(db, "bind id")
                }
                try blob.withUnsafeBytes { raw in
                    guard sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), Self.transientDestructor) == SQLITE_OK else {
                        throw Self.error(db, "bind row")
                    }
                }
                // Plain INSERT (not OR REPLACE): a duplicate id in a torn export
                // raises SQLITE_CONSTRAINT, which fails the whole replace and
                // rolls back — keeping the last-good clone, matching the NDJSON
                // parser's fail-closed posture.
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw Self.error(db, "insert id \(row.id)")
                }
            }
            try Self.setWatermark(db, lastModified)
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

    private static func decodeRow(_ stmt: OpaquePointer) throws -> CatalogRow? {
        guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        let data = Data(bytes: bytes, count: count)
        return try JSONCoders.decoder.decode(CatalogRow.self, from: data)
    }

    private static func setWatermark(_ db: OpaquePointer, _ value: String?) throws {
        guard let value else {
            try exec(db, "DELETE FROM meta WHERE key = 'last_modified';")
            return
        }
        let stmt = try prepare(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_modified', ?);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, value, -1, transientDestructor) == SQLITE_OK else {
            throw error(db, "bind watermark")
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error(db, "step watermark") }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw CatalogStoreError.sqlite("exec '\(sql.prefix(40))': \(message)")
        }
    }

    private static func error(_ db: OpaquePointer, _ context: String) -> CatalogStoreError {
        .sqlite("\(context): \(String(cString: sqlite3_errmsg(db)))")
    }
}
