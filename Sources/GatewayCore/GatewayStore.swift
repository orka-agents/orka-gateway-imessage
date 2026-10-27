import CryptoKit
import Foundation
import SQLite3

public enum DeliveryState: String, Sendable, Equatable {
    case sending
    case retryable
    case delivered
    case permanent
    /// Terminal: retrying an ambiguous send could duplicate it.
    case unknown

    /// Whether a delivery must be replayed rather than sent.
    public var isTerminal: Bool {
        self == .delivered || self == .permanent || self == .unknown
    }
}

/// The idempotency record for one logical Orka delivery.
public struct DeliveryRecord: Sendable, Equatable {
    public var idempotencyID: String
    public var requestDigest: String
    public var state: DeliveryState
    public var providerMessageID: String
    public var safeMessage: String
    public var chatGUID: String
    public var textDigest: String
    public var updatedAt: Date
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case sqlite(String)
    case invalidPath
    case newerSchema(Int64)
    case digestConflict
    case invalidTransition
    case invalidCursor

    public var description: String {
        switch self {
        case let .sqlite(message): "sqlite: \(message)"
        case .invalidPath: "a filesystem database path is required"
        case let .newerSchema(version): "database schema version \(version) is newer than this gateway supports"
        case .digestConflict: "delivery idempotency conflict"
        case .invalidTransition: "invalid delivery state transition"
        case .invalidCursor: "cursor row is invalid"
        }
    }
}

/// The gateway's durable state in SQLite: the inbound watch cursor, outgoing
/// self-chat rows, chats admitted to Orka, and outbound delivery idempotency.
/// One database file belongs to one gateway process; opening it marks
/// interrupted sends as unknown.
public actor GatewayStore {
    public static let outcomeUnknownAfterRestart = "iMessage delivery outcome is unknown after gateway restart"
    private static let schemaVersion: Int64 = 1

    private let database: SQLiteDatabase

    public init(path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ":memory:", !trimmed.hasPrefix("file:") else {
            throw StoreError.invalidPath
        }
        let url = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let database = try SQLiteDatabase(path: url.path)
        try Self.initialize(database)
        if chmod(url.path, 0o600) != 0 {
            throw StoreError.sqlite("restrict database permissions")
        }
        self.database = database
    }

    private static func initialize(_ database: SQLiteDatabase) throws {
        try database.execute("PRAGMA busy_timeout = 5000")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = FULL")
        let version = try database.query("PRAGMA user_version") { $0.int64(0) }.first ?? 0
        switch version {
        case 0:
            try database.transaction {
                try database.execute("""
                CREATE TABLE watch_cursor (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    last_rowid INTEGER NOT NULL CHECK (last_rowid >= 0),
                    updated_at_ms INTEGER NOT NULL
                );
                CREATE TABLE outgoing_rows (
                    chat_guid TEXT NOT NULL,
                    text_digest TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    recorded_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (chat_guid, text_digest, created_at_ms)
                );
                CREATE TABLE reply_chats (
                    chat_guid TEXT PRIMARY KEY,
                    first_seen_at_ms INTEGER NOT NULL,
                    last_inbound_at_ms INTEGER NOT NULL
                );
                CREATE TABLE deliveries (
                    idempotency_id TEXT PRIMARY KEY,
                    request_digest TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('sending','retryable','delivered','permanent','unknown')),
                    provider_message_id TEXT NOT NULL DEFAULT '',
                    safe_message TEXT NOT NULL DEFAULT '',
                    chat_guid TEXT NOT NULL,
                    text_digest TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );
                CREATE INDEX deliveries_echo ON deliveries (chat_guid, text_digest, updated_at_ms);
                PRAGMA user_version = 1;
                """)
            }
        case schemaVersion:
            break
        default:
            throw StoreError.newerSchema(version)
        }
        try database.run(
            "UPDATE deliveries SET state = 'unknown', safe_message = ?, updated_at_ms = ? WHERE state = 'sending'",
            .text(outcomeUnknownAfterRestart), .int(nowMillis())
        )
    }

    /// Verifies the database can serve reads.
    public func ping() throws {
        _ = try database.query("SELECT 1") { $0.int64(0) }
    }

    /// Returns the highest processed Messages row. `initialized` is false
    /// until `initializeCursor` or `advanceCursor` first records a position.
    public func cursor() throws -> (rowID: Int64, initialized: Bool) {
        let rows = try database.query("SELECT last_rowid FROM watch_cursor WHERE id = 1") { $0.int64(0) }
        guard let rowID = rows.first else { return (0, false) }
        return (rowID, true)
    }

    /// Records the starting position once; later calls keep the existing
    /// cursor. Row 0 means the Messages database had no rows.
    public func initializeCursor(_ rowID: Int64) throws {
        guard rowID >= 0 else { throw StoreError.invalidCursor }
        try database.run(
            "INSERT INTO watch_cursor (id, last_rowid, updated_at_ms) VALUES (1, ?, ?) ON CONFLICT (id) DO NOTHING",
            .int(rowID), .int(Self.nowMillis())
        )
    }

    /// Records rowID as processed. The cursor never moves backwards.
    public func advanceCursor(_ rowID: Int64) throws {
        guard rowID > 0 else { throw StoreError.invalidCursor }
        try database.run(
            """
            INSERT INTO watch_cursor (id, last_rowid, updated_at_ms) VALUES (1, ?, ?)
            ON CONFLICT (id) DO UPDATE SET last_rowid = MAX(last_rowid, excluded.last_rowid),
                updated_at_ms = excluded.updated_at_ms
            """,
            .int(rowID), .int(Self.nowMillis())
        )
    }

    /// Records a row this Messages account sent in an allowlisted chat, keyed
    /// by chat, text, and creation time.
    public func recordOutgoingRow(chatGUID: String, textDigest: String, createdAt: Date) throws {
        try database.run(
            """
            INSERT INTO outgoing_rows (chat_guid, text_digest, created_at_ms, recorded_at_ms)
            VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING
            """,
            .text(chatGUID), .text(textDigest), .int(Self.millis(createdAt)), .int(Self.nowMillis())
        )
    }

    /// Reports whether an outgoing row with exactly this chat, text, and
    /// creation time was recorded. In a self-chat, Messages stores one send
    /// as an outgoing row plus received copies, and the copies that carry the
    /// outgoing row's exact timestamp are not separate messages.
    public func hasOutgoingRow(chatGUID: String, textDigest: String, createdAt: Date) throws -> Bool {
        try !database.query(
            "SELECT 1 FROM outgoing_rows WHERE chat_guid = ? AND text_digest = ? AND created_at_ms = ?",
            .text(chatGUID), .text(textDigest), .int(Self.millis(createdAt))
        ) { $0.int64(0) }.isEmpty
    }

    /// Records that an allowlisted inbound message arrived in chatGUID.
    public func rememberReplyChat(_ chatGUID: String) throws {
        let now = Self.nowMillis()
        try database.run(
            """
            INSERT INTO reply_chats (chat_guid, first_seen_at_ms, last_inbound_at_ms) VALUES (?, ?, ?)
            ON CONFLICT (chat_guid) DO UPDATE SET last_inbound_at_ms = excluded.last_inbound_at_ms
            """,
            .text(chatGUID), .int(now), .int(now)
        )
    }

    /// Reports whether chatGUID previously produced an admitted inbound message.
    public func replyChatKnown(_ chatGUID: String) throws -> Bool {
        try !database.query("SELECT 1 FROM reply_chats WHERE chat_guid = ?", .text(chatGUID)) { $0.int64(0) }.isEmpty
    }

    /// Reports whether the gateway sent (or may have sent) text with
    /// textDigest to chatGUID within window of `at`, the time a Messages row
    /// was created. Keying on the row's own time drops echoes even when they
    /// are processed late.
    public func sentNear(chatGUID: String, textDigest: String, at: Date, window: TimeInterval) throws -> Bool {
        try !database.query(
            """
            SELECT 1 FROM deliveries
            WHERE chat_guid = ? AND text_digest = ? AND state IN ('sending','delivered','unknown')
                AND created_at_ms <= ? AND updated_at_ms >= ?
            LIMIT 1
            """,
            .text(chatGUID), .text(textDigest),
            .int(Self.millis(at.addingTimeInterval(window))), .int(Self.millis(at.addingTimeInterval(-window)))
        ) { $0.int64(0) }.isEmpty
    }

    /// Returns the record for idempotencyID, if any.
    public func delivery(_ idempotencyID: String) throws -> DeliveryRecord? {
        try database.query(Self.deliverySelect + " WHERE idempotency_id = ?", .text(idempotencyID), map: Self.deliveryRecord).first
    }

    /// Atomically creates a sending record or reclaims a retryable one.
    /// `shouldSend` is false for terminal and in-flight records, which callers
    /// replay instead of sending again.
    public func claimDelivery(
        idempotencyID: String,
        requestDigest: String,
        chatGUID: String,
        textDigest: String
    ) throws -> (record: DeliveryRecord, shouldSend: Bool) {
        try database.transaction {
            let now = Self.nowMillis()
            guard var record = try database.query(
                Self.deliverySelect + " WHERE idempotency_id = ?", .text(idempotencyID), map: Self.deliveryRecord
            ).first else {
                try database.run(
                    """
                    INSERT INTO deliveries
                        (idempotency_id, request_digest, state, chat_guid, text_digest, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'sending', ?, ?, ?, ?)
                    """,
                    .text(idempotencyID), .text(requestDigest), .text(chatGUID), .text(textDigest), .int(now), .int(now)
                )
                let record = DeliveryRecord(
                    idempotencyID: idempotencyID, requestDigest: requestDigest, state: .sending,
                    providerMessageID: "", safeMessage: "", chatGUID: chatGUID, textDigest: textDigest,
                    updatedAt: Self.date(millis: now)
                )
                return (record, true)
            }
            guard record.requestDigest == requestDigest else { throw StoreError.digestConflict }
            guard record.state == .retryable else { return (record, false) }
            try database.run(
                """
                UPDATE deliveries SET state = 'sending', provider_message_id = '', safe_message = '', updated_at_ms = ?
                WHERE idempotency_id = ? AND state = 'retryable'
                """,
                .int(now), .text(idempotencyID)
            )
            record.state = .sending
            record.providerMessageID = ""
            record.safeMessage = ""
            record.updatedAt = Self.date(millis: now)
            return (record, true)
        }
    }

    /// Records the outcome of a claimed send.
    public func finishDelivery(
        idempotencyID: String,
        requestDigest: String,
        state: DeliveryState,
        providerMessageID: String,
        safeMessage: String
    ) throws -> DeliveryRecord {
        guard state != .sending else { throw StoreError.invalidTransition }
        let changed = try database.run(
            """
            UPDATE deliveries SET state = ?, provider_message_id = ?, safe_message = ?, updated_at_ms = ?
            WHERE idempotency_id = ? AND request_digest = ? AND state = 'sending'
            """,
            .text(state.rawValue), .text(providerMessageID), .text(safeMessage), .int(Self.nowMillis()),
            .text(idempotencyID), .text(requestDigest)
        )
        guard changed == 1, let record = try delivery(idempotencyID) else { throw StoreError.invalidTransition }
        return record
    }

    private static let deliverySelect = """
    SELECT idempotency_id, request_digest, state, provider_message_id, safe_message, chat_guid, text_digest, updated_at_ms
    FROM deliveries
    """

    private static func deliveryRecord(_ row: SQLiteRow) throws -> DeliveryRecord {
        guard let state = DeliveryState(rawValue: row.text(2)) else {
            throw StoreError.sqlite("unknown delivery state")
        }
        return DeliveryRecord(
            idempotencyID: row.text(0), requestDigest: row.text(1), state: state, providerMessageID: row.text(3),
            safeMessage: row.text(4), chatGUID: row.text(5), textDigest: row.text(6),
            updatedAt: date(millis: row.int64(7))
        )
    }

    static func nowMillis() -> Int64 { millis(Date()) }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func date(millis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}

public enum Digest {
    /// Returns a hex SHA-256 digest.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Digests message text after normalizing line endings and edges, so an
    /// echoed send matches the text the gateway sent.
    public static func text(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return sha256(Data(normalized.utf8))
    }
}

// MARK: - SQLite

enum SQLiteValue {
    case int(Int64)
    case text(String)
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
}

/// A minimal wrapper around one SQLite connection. Callers serialize access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw StoreError.sqlite(message)
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    @discardableResult
    func run(_ sql: String, _ values: SQLiteValue...) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ values: SQLiteValue..., map: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(try map(SQLiteRow(statement: statement)))
            case SQLITE_DONE:
                return rows
            default:
                throw error()
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result = switch value {
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error()
            }
        }
        return statement
    }

    private func error() -> StoreError {
        StoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}
