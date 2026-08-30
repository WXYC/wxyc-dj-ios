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

    /// Set once ``ensureSearchIndex()`` has confirmed the FTS index covers the
    /// catalog rows for this connection (issue #58). A latch, not a gate: once
    /// true, the cheap per-search reconciliation check is skipped, because every
    /// ``replace(rows:lastModified:)`` rebuilds the index alongside the rows and
    /// so preserves the invariant.
    private var searchIndexEnsured = false

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
            // Offline search index (issue #58). A contentless (`content=''`)
            // external-content FTS5 table: it stores only the searchable terms
            // keyed by `rowid = catalog.id`, never the original text (that lives
            // in the `catalog` BLOB). `remove_diacritics 2` folds accents so
            // "nilufer" matches "Nilüfer Yanya". Apple's system libsqlite3 ships
            // FTS5 on iOS/macOS, so this CREATE succeeds on every supported
            // platform; a "no such module: fts5" failure here would surface as a
            // store-open error rather than silent corruption.
            try Self.exec(handle, """
                CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(
                    artist, album, call_number,
                    content='', tokenize='unicode61 remove_diacritics 2'
                );
                """)
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

    /// One `WHERE id IN (…)` query rather than the protocol default's N
    /// sequential `row(id:)` awaits — the digital-archive badge's one batch
    /// read per search-result page (issue #136). Empty `ids` skips the query
    /// entirely (SQLite tolerates `IN ()` as always-false, but there's nothing
    /// to ask for).
    public func rows(ids: [Int]) throws -> [Int: CatalogRow] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let stmt = try Self.prepare(db, "SELECT id, row FROM catalog WHERE id IN (\(placeholders));")
        defer { sqlite3_finalize(stmt) }
        for (offset, id) in ids.enumerated() {
            guard sqlite3_bind_int64(stmt, Int32(offset + 1), Int64(id)) == SQLITE_OK else {
                throw Self.error(db, "bind id \(offset)")
            }
        }
        var results: [Int: CatalogRow] = [:]
        rowLoop: while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                let id = Int(sqlite3_column_int64(stmt, 0))
                guard let bytes = sqlite3_column_blob(stmt, 1) else { continue }
                let count = Int(sqlite3_column_bytes(stmt, 1))
                let data = Data(bytes: bytes, count: count)
                results[id] = try JSONCoders.decoder.decode(CatalogRow.self, from: data)
            case SQLITE_DONE: break rowLoop
            default: throw Self.error(db, "step select ids")
            }
        }
        return results
    }

    public func count() throws -> Int {
        let stmt = try Self.prepare(db, "SELECT COUNT(*) FROM catalog;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Self.error(db, "step count") }
        return Int(sqlite3_column_int64(stmt, 0))
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
            try Self.rebuildSearchIndex(db, rows: rows)
            try Self.setWatermark(db, lastModified)
            try Self.exec(db, "COMMIT;")
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
    }

    public func search(query: String, limit: Int) throws -> [CatalogRow] {
        guard let match = FTSQuery.match(for: query) else { return [] }
        try ensureSearchIndex()
        var ids: [Int] = []
        let stmt = try Self.prepare(
            db, "SELECT rowid FROM catalog_fts WHERE catalog_fts MATCH ? ORDER BY rank LIMIT ?;"
        )
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, match, -1, Self.transientDestructor) == SQLITE_OK else {
            throw Self.error(db, "bind match")
        }
        guard sqlite3_bind_int64(stmt, 2, Int64(limit)) == SQLITE_OK else {
            throw Self.error(db, "bind limit")
        }
        rowLoop: while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: ids.append(Int(sqlite3_column_int64(stmt, 0)))
            case SQLITE_DONE: break rowLoop
            default: throw Self.error(db, "step search")
            }
        }
        // Load the full row BLOB for each match, preserving the rank order. The
        // FTS table is contentless, so the searchable text alone isn't enough —
        // the authoritative row lives in `catalog`.
        var results: [CatalogRow] = []
        results.reserveCapacity(ids.count)
        for id in ids {
            if let row = try row(id: id) { results.append(row) }
        }
        return results
    }

    // MARK: Private SQLite helpers

    /// Backfill the FTS index from the existing catalog rows when it doesn't yet
    /// cover them — the one-time migration for installs that cloned the catalog
    /// before issue #58 added the index. Such a store has a populated `catalog`
    /// table but an empty `catalog_fts` (the `CREATE … IF NOT EXISTS` in `init`
    /// makes the table, but only ``replace(rows:lastModified:)`` — which runs on a
    /// `200` — fills it, so a `304` refresh would otherwise leave offline search
    /// returning nothing indefinitely). It rebuilds the index from the rows
    /// without touching the watermark, so the conditional-GET path is undisturbed.
    ///
    /// Steady state pays only two `COUNT`s (the index and rows are rebuilt
    /// together by `replace`, so they always match), then latches; a fresh/empty
    /// store is a no-op. Runs inside the actor (off the main thread) and only when
    /// offline search is actually exercised, so it never delays launch.
    private func ensureSearchIndex() throws {
        guard !searchIndexEnsured else { return }
        let db = connection.db
        let catalogCount = try Self.scalarInt(db, "SELECT COUNT(*) FROM catalog;")
        let indexCount = try Self.scalarInt(db, "SELECT COUNT(*) FROM catalog_fts;")
        if catalogCount != indexCount {
            let rows = try Self.allRows(db)
            try Self.exec(db, "BEGIN IMMEDIATE;")
            do {
                try Self.rebuildSearchIndex(db, rows: rows)
                try Self.exec(db, "COMMIT;")
            } catch {
                try? Self.exec(db, "ROLLBACK;")
                throw error
            }
        }
        searchIndexEnsured = true
    }

    /// Run a single-column, single-row integer query (e.g. a `COUNT(*)`).
    private static func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error(db, "step scalar \(sql.prefix(40))") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Decode every stored `CatalogRow` BLOB. Used by the FTS backfill — the
    /// `catalog` table is the source of truth, and the searchable text (artist /
    /// album / call number) is only recoverable by decoding the rows.
    private static func allRows(_ db: OpaquePointer) throws -> [CatalogRow] {
        let stmt = try prepare(db, "SELECT row FROM catalog;")
        defer { sqlite3_finalize(stmt) }
        var rows: [CatalogRow] = []
        loop: while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                if let row = try decodeRow(stmt) { rows.append(row) }
            case SQLITE_DONE:
                break loop
            default:
                throw error(db, "step all rows")
            }
        }
        return rows
    }

    /// Rebuild the contentless FTS index from `rows`, inside the caller's open
    /// transaction. A `content=''` fts5 table rejects `DELETE FROM`, so the whole
    /// index is cleared with the documented `'delete-all'` command, then each
    /// row's searchable text (artist / album / call number) is re-inserted keyed
    /// by `rowid = catalog.id`. Any failure throws and the caller rolls back, so
    /// the index and the rows commit (or revert) together — they can't drift.
    private static func rebuildSearchIndex(_ db: OpaquePointer, rows: [CatalogRow]) throws {
        try exec(db, "INSERT INTO catalog_fts (catalog_fts) VALUES ('delete-all');")
        let stmt = try prepare(
            db, "INSERT INTO catalog_fts (rowid, artist, album, call_number) VALUES (?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            guard sqlite3_bind_int64(stmt, 1, Int64(row.id)) == SQLITE_OK else {
                throw error(db, "bind fts id")
            }
            guard sqlite3_bind_text(stmt, 2, row.artistName, -1, transientDestructor) == SQLITE_OK else {
                throw error(db, "bind fts artist")
            }
            guard sqlite3_bind_text(stmt, 3, row.albumTitle, -1, transientDestructor) == SQLITE_OK else {
                throw error(db, "bind fts album")
            }
            guard sqlite3_bind_text(stmt, 4, row.callNumber, -1, transientDestructor) == SQLITE_OK else {
                throw error(db, "bind fts call number")
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw error(db, "insert fts id \(row.id)")
            }
        }
    }

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
