import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    var code: Int32
    var message: String
    var description: String { "SQLite error \(code): \(message)" }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// sqlite3 C API 래퍼. 연결 하나. 스레드 안전하지 않음(호출자가 액터나 락으로 보호).
final class SQLiteConnection {
    fileprivate let db: OpaquePointer

    init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        return SQLiteStatement(stmt: stmt, connection: self)
    }

    func lastInsertRowId() -> Int64 { sqlite3_last_insert_rowid(db) }
}

final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let connection: SQLiteConnection   // 연결이 문장보다 먼저 닫히지 않게 붙잡음

    fileprivate init(stmt: OpaquePointer, connection: SQLiteConnection) {
        self.stmt = stmt
        self.connection = connection
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ idx: Int32, _ v: Int64?) {
        if let v { sqlite3_bind_int64(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }
    func bind(_ idx: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(stmt, idx, v) } else { sqlite3_bind_null(stmt, idx) }
    }
    func bind(_ idx: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, idx) }
    }

    /// 행이 있으면 true, 끝이면 false.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(connection.db)))
        }
    }

    /// 다음 실행을 위해 되돌리고 바인딩을 지웁니다.
    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func int64(_ col: Int32) -> Int64? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, col)
    }
    func double(_ col: Int32) -> Double? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
    }
    func text(_ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL, let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
