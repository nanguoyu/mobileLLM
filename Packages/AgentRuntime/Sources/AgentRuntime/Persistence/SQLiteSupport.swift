// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

enum SQLiteValue: Sendable {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null
}

enum SQLiteStoreError: Error, Sendable, Equatable {
    case unavailable(String)
    case locked
    case diskFull
    case corrupt
    case dataProtectionUnavailable(String)
    case migrationFailed(backup: URL?, message: String)
    case unsupportedSchema(Int32)
    case invariantViolation(String)
    case injected(SQLiteJournalFaultPoint)
}

final class SQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    let url: URL

    init(url: URL, create: Bool, readOnly: Bool = false, immutable: Bool = false) throws {
        self.url = url
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0) : SQLITE_OPEN_READWRITE)
            | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        let filename = immutable ? url.absoluteString + "?immutable=1" : url.path
        let result = sqlite3_open_v2(filename, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message: String
            if let database {
                message = String(cString: sqlite3_errmsg(database))
            } else {
                message = "sqlite open failed"
            }
            if let database { sqlite3_close_v2(database) }
            throw SQLiteStoreError.unavailable(message)
        }
        handle = database
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        guard let handle else { throw SQLiteStoreError.unavailable("database is closed") }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw SQLiteStoreError.unavailable("statement preparation failed") }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw mappedError(result) }
        }
    }

    func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        guard let handle else { throw SQLiteStoreError.unavailable("database is closed") }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw SQLiteStoreError.unavailable("statement preparation failed") }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var output: [[SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw mappedError(result) }
            var row: [SQLiteValue] = []
            for index in 0 ..< sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(statement, index))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 { row.append(.blob(Data())) }
                    else if let bytes = sqlite3_column_blob(statement, index) {
                        row.append(.blob(Data(bytes: bytes, count: count)))
                    } else { row.append(.blob(Data())) }
                default:
                    row.append(.null)
                }
            }
            output.append(row)
        }
    }

    func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
        guard let first = try rows(sql, values).first?.first else { return nil }
        guard case .integer(let value) = first else { return nil }
        return value
    }

    func scalarText(_ sql: String, _ values: [SQLiteValue] = []) throws -> String? {
        guard let first = try rows(sql, values).first?.first else { return nil }
        guard case .text(let value) = first else { return nil }
        return value
    }

    func consistentBackup(to destinationURL: URL) throws {
        guard let source = handle else { throw SQLiteStoreError.unavailable("database is closed") }
        var destination: OpaquePointer?
        let opened = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw mappedError(opened)
        }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteStoreError.unavailable(String(cString: sqlite3_errmsg(destination)))
        }
        defer { sqlite3_backup_finish(backup) }
        let copied = sqlite3_backup_step(backup, -1)
        guard copied == SQLITE_DONE else { throw mappedError(copied) }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            try check(result)
        }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw mappedError(result) }
    }

    private func mappedError(_ result: Int32) -> SQLiteStoreError {
        let primary = result & 0xff
        switch primary {
        case SQLITE_BUSY, SQLITE_LOCKED: return .locked
        case SQLITE_FULL: return .diskFull
        case SQLITE_CORRUPT, SQLITE_NOTADB: return .corrupt
        default:
            let message: String
            if let handle {
                message = String(cString: sqlite3_errmsg(handle))
            } else {
                message = "SQLite error \(result)"
            }
            return .unavailable(message)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteValue {
    var text: String? { if case .text(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var blob: Data? { if case .blob(let value) = self { value } else { nil } }
}
