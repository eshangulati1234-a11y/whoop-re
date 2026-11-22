import Foundation
import SQLite3

struct Sample: Codable, Identifiable {
    var id: String
    var date: Date
    var bpm: Int
}

/// Call only on the manager's serial executor. A batch is durable before ACK.
final class HistoryStore {
    let url: URL
    private var db: OpaquePointer?
    enum Failure: Error { case database(String) }
    init(url: URL) throws {
        self.url = url
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure.database("Cannot open history database") }
        // The calibration worker and the main thread each hold a connection; wait for a lock instead of failing.
        sqlite3_busy_timeout(db, 5000)
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS frames(device TEXT NOT NULL, payload BLOB NOT NULL, received REAL NOT NULL, UNIQUE(device,payload)); CREATE TABLE IF NOT EXISTS samples(id TEXT PRIMARY KEY, time REAL NOT NULL, bpm INTEGER NOT NULL);")
            var versionStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK else { throw Failure.database("Cannot read schema version") }
            guard sqlite3_step(versionStatement) == SQLITE_ROW else { sqlite3_finalize(versionStatement); throw Failure.database("Cannot read schema version") }
            let version = sqlite3_column_int(versionStatement, 0); sqlite3_finalize(versionStatement)
            guard version <= 5 else { throw Failure.database("Database belongs to a newer app; refusing downgrade") }
            if version < 2 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE INDEX IF NOT EXISTS samples_time ON samples(time); CREATE TABLE IF NOT EXISTS live_minutes(minute INTEGER PRIMARY KEY,bpm_avg REAL,bpm_min INTEGER,bpm_max INTEGER,count INTEGER,rr_rmssd REAL); PRAGMA user_version=2; COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            if version < 3 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE IF NOT EXISTS detected_activities(id TEXT PRIMARY KEY,start REAL NOT NULL,end REAL NOT NULL,status TEXT NOT NULL,payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS detected_end ON detected_activities(end); CREATE TABLE IF NOT EXISTS sleeps(wake_day INTEGER PRIMARY KEY,payload TEXT NOT NULL); PRAGMA user_version=3; COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            if version < 4 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE health_documents(key TEXT PRIMARY KEY,payload BLOB NOT NULL); CREATE TABLE metric_revisions(id INTEGER PRIMARY KEY AUTOINCREMENT,key TEXT NOT NULL,payload BLOB NOT NULL,created REAL NOT NULL); ALTER TABLE live_minutes ADD COLUMN rr_count INTEGER; PRAGMA user_version=4; COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            if version < 5 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute(Self.v5Schema + "PRAGMA user_version=5")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
                try rebuildRecords()
            }
            // Raw optical (light sensor) frames from short spot checks, kept for blood-oxygen decoding.
            try execute("CREATE TABLE IF NOT EXISTS optical_frames(received REAL NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS optical_received ON optical_frames(received);")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    private static let v5Schema = """
        CREATE TABLE IF NOT EXISTS records(time INTEGER PRIMARY KEY,counter INTEGER,bpm INTEGER,rr BLOB,gx REAL,gy REAL,gz REAL,red INTEGER,ir INTEGER,skin_raw INTEGER);
        CREATE TABLE IF NOT EXISTS history_minutes(minute INTEGER PRIMARY KEY,bpm_avg REAL,bpm_min INTEGER,bpm_max INTEGER,count INTEGER,motion REAL,rr_pairs INTEGER,rr_sumsq REAL,red_ir REAL,skin_raw REAL);
        CREATE TABLE IF NOT EXISTS sync_cursors(time REAL,token BLOB,records INTEGER);

        """
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
    }
    func persist(_ frames: [[UInt8]], device: String, cursor: [UInt8]? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let frameStatement = try prepare("INSERT OR IGNORE INTO frames VALUES(?,?,?)")
            let sampleStatement = try prepare("INSERT OR IGNORE INTO samples VALUES(?,?,?)")
            defer { sqlite3_finalize(frameStatement); sqlite3_finalize(sampleStatement) }
            let received = Date().timeIntervalSince1970
            var records: [HistoryProtocol.Record] = []
            for frame in frames {
                sqlite3_reset(frameStatement)
                sqlite3_bind_text(frameStatement, 1, device, -1, Self.transient)
                _ = frame.withUnsafeBytes { sqlite3_bind_blob(frameStatement, 2, $0.baseAddress, Int32(frame.count), Self.transient) }
                sqlite3_bind_double(frameStatement, 3, received)
                guard sqlite3_step(frameStatement) == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
                if let sample = HistoryProtocol.sample(frame, device: device) {
                    sqlite3_reset(sampleStatement)
                    sqlite3_bind_text(sampleStatement, 1, sample.id, -1, Self.transient)
                    sqlite3_bind_double(sampleStatement, 2, sample.date.timeIntervalSince1970); sqlite3_bind_int(sampleStatement, 3, Int32(sample.bpm))
                    guard sqlite3_step(sampleStatement) == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
                }
                if let record = HistoryProtocol.record(frame) { records.append(record) }
            }
            try storeRecords(records)
            if let cursor {
                let statement = try prepare("INSERT INTO sync_cursors VALUES(?,?,?)")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, received)
                _ = cursor.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(cursor.count), Self.transient) }
                sqlite3_bind_int(statement, 3, Int32(records.count))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot save cursor") }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    /// Insert decoded records and recompute the minutes they touch. Call inside a transaction.
    private func storeRecords(_ records: [HistoryProtocol.Record]) throws {
        guard !records.isEmpty else { return }
        let insert = try prepare("INSERT OR IGNORE INTO records VALUES(?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        for r in records {
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, Int64(r.time)); sqlite3_bind_int64(insert, 2, Int64(r.counter)); sqlite3_bind_int(insert, 3, Int32(r.bpm))
            let blob = r.rr.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(insert, 4, $0.baseAddress, Int32(blob.count), Self.transient) }
            if let g = r.gravity { for i in 0..<3 { sqlite3_bind_double(insert, 5 + Int32(i), Double(g[i])) } }
            else { for i in 0..<3 { sqlite3_bind_null(insert, 5 + Int32(i)) } }
            sqlite3_bind_int(insert, 8, Int32(r.red)); sqlite3_bind_int(insert, 9, Int32(r.ir)); sqlite3_bind_int(insert, 10, Int32(r.skinRaw))
            guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.database("Cannot insert record") }
        }
        let minutes = Set(records.map { Int64($0.time / 60) })
        try recomputeMinutes(minutes)
    }
    private func recomputeMinutes(_ minutes: Set<Int64>) throws {
        let query = try prepare("SELECT time,counter,bpm,rr,gx,gy,gz,red,ir,skin_raw FROM records WHERE time>=? AND time<? ORDER BY time")
        let write = try prepare("INSERT OR REPLACE INTO history_minutes VALUES(?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(query); sqlite3_finalize(write) }
        for minute in minutes.sorted() {
            sqlite3_reset(query); sqlite3_bind_int64(query, 1, minute * 60); sqlite3_bind_int64(query, 2, minute * 60 + 60)
            var rows: [HistoryProtocol.Record] = []
            while sqlite3_step(query) == SQLITE_ROW {
                var rr: [Int] = []
                if let pointer = sqlite3_column_blob(query, 3) {
                    let bytes = UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: Int(sqlite3_column_bytes(query, 3)))
                    rr = stride(from: 0, to: bytes.count - 1, by: 2).map { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
                }
                let gravity: [Float]? = sqlite3_column_type(query, 4) == SQLITE_NULL ? nil : (4..<7).map { Float(sqlite3_column_double(query, Int32($0))) }
                rows.append(.init(time: Int(sqlite3_column_int64(query, 0)), counter: UInt32(truncatingIfNeeded: sqlite3_column_int64(query, 1)), bpm: Int(sqlite3_column_int(query, 2)),
                                  rr: rr, gravity: gravity, red: Int(sqlite3_column_int(query, 7)), ir: Int(sqlite3_column_int(query, 8)), skinRaw: Int(sqlite3_column_int(query, 9))))
            }
            guard let m = HRTimeline.aggregate(rows).first else { continue }
            sqlite3_reset(write)
            sqlite3_bind_int64(write, 1, m.minute); sqlite3_bind_double(write, 2, m.bpmAverage); sqlite3_bind_int(write, 3, Int32(m.bpmMinimum)); sqlite3_bind_int(write, 4, Int32(m.bpmMaximum)); sqlite3_bind_int(write, 5, Int32(m.count))
            if let v = m.motion { sqlite3_bind_double(write, 6, v) } else { sqlite3_bind_null(write, 6) }
            sqlite3_bind_int(write, 7, Int32(m.rrPairs)); sqlite3_bind_double(write, 8, m.rrSumSquares)
            if let v = m.redIR { sqlite3_bind_double(write, 9, v) } else { sqlite3_bind_null(write, 9) }
            if let v = m.skinRaw { sqlite3_bind_double(write, 10, v) } else { sqlite3_bind_null(write, 10) }
            guard sqlite3_step(write) == SQLITE_DONE else { throw Failure.database("Cannot save minute") }
        }
    }
    /// Rebuild `records` and `history_minutes` from the stored raw frames (used once by the v5 migration).
    func rebuildRecords() throws {
        let statement = try prepare("SELECT payload FROM frames WHERE substr(payload,1,1)=X'2F' AND length(payload)=96")
        var records: [HistoryProtocol.Record] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let pointer = sqlite3_column_blob(statement, 0),
               let record = HistoryProtocol.record(Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))) { records.append(record) }
        }
        sqlite3_finalize(statement)
        try execute("BEGIN IMMEDIATE")
        do { try storeRecords(records); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
    /// Decoded minutes in `[from, to)`, keyed by minute number.
    func historyMinutes(from: Date, to: Date) throws -> [Int64: HistoryMinute] {
        let statement = try prepare("SELECT minute,bpm_avg,bpm_min,bpm_max,count,motion,rr_pairs,rr_sumsq,red_ir,skin_raw FROM history_minutes WHERE minute>=? AND minute<?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(floor(from.timeIntervalSince1970 / 60))); sqlite3_bind_int64(statement, 2, Int64(ceil(to.timeIntervalSince1970 / 60)))
        var result: [Int64: HistoryMinute] = [:]
        func optional(_ i: Int32) -> Double? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : sqlite3_column_double(statement, i) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let minute = sqlite3_column_int64(statement, 0)
            result[minute] = HistoryMinute(minute: minute, bpmAverage: sqlite3_column_double(statement, 1), bpmMinimum: Int(sqlite3_column_int(statement, 2)), bpmMaximum: Int(sqlite3_column_int(statement, 3)),
                                           count: Int(sqlite3_column_int(statement, 4)), motion: optional(5), rrPairs: Int(sqlite3_column_int(statement, 6)), rrSumSquares: sqlite3_column_double(statement, 7),
                                           redIR: optional(8), skinRaw: optional(9))
        }
        return result
    }
    /// Re-run decoding without moving the band's persistent history cursor.
    func replaySavedFrames() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT device,payload FROM frames WHERE substr(payload,1,1)=X'2F'", -1, &statement, nil) == SQLITE_OK else { throw Failure.database("Cannot read saved frames") }
        defer { sqlite3_finalize(statement) }
        var records: [(String, [UInt8])] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            let device = String(cString: sqlite3_column_text(statement, 0))
            let count = Int(sqlite3_column_bytes(statement, 1))
            if let pointer = sqlite3_column_blob(statement, 1) {
                records.append((device, Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))))
            }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot replay saved frames") }
        let grouped = Dictionary(grouping: records, by: { $0.0 })
        for (device, entries) in grouped { try persist(entries.map { $0.1 }, device: device) }
    }
    func diagnostics() throws -> String {
        var statement: OpaquePointer?
        // The second byte is a sequence number on many packet types, not a subtype.
        // Aggregate by packet type so console traffic cannot hide historical records.
        let sql = "SELECT hex(substr(payload,1,1)),MIN(length(payload)),MAX(length(payload)),COUNT(*) FROM frames GROUP BY substr(payload,1,1) ORDER BY substr(payload,1,1)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.database("Cannot read diagnostics") }
        defer { sqlite3_finalize(statement) }
        let names = ["24": "Command response", "28": "Live data", "2B": "Live raw data", "2F": "Historical data", "30": "Event", "31": "Sync marker", "32": "Console log"]
        var rows = ["Saved packet diagnostics v4 (unique frames across all syncs)"]
        var code = sqlite3_step(statement)
        var hasHistory = false
        while code == SQLITE_ROW {
            let type = String(cString: sqlite3_column_text(statement, 0))
            hasHistory = hasHistory || type == "2F"
            rows.append("\(names[type] ?? "Unknown") 0x\(type) · \(sqlite3_column_int(statement, 1))–\(sqlite3_column_int(statement, 2)) bytes · \(sqlite3_column_int(statement, 3)) saved")
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot read diagnostics") }
        if !hasHistory { rows.append("No historical (0x2F) records saved. A completion marker alone does not confirm measurements were downloaded.") }
        var history: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT device,payload FROM frames WHERE substr(payload,1,1)=X'2F' ORDER BY received DESC LIMIT 8", -1, &history, nil) == SQLITE_OK else { throw Failure.database("Cannot inspect history") }
        defer { sqlite3_finalize(history) }
        code = sqlite3_step(history)
        while code == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(history, 1))
            if let pointer = sqlite3_column_blob(history, 1) {
                let bytes = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))
                let prefix = bytes.prefix(24).map { String(format: "%02X", $0) }.joined()
                rows.append("History example · \(count) bytes · \(HistoryProtocol.rejectionReason(bytes) ?? "decoded HR") · header \(prefix)")
            }
            code = sqlite3_step(history)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot inspect history") }
        rows += try diagnosticRows(
            "SELECT hex(substr(payload,3,1)),COUNT(*) FROM frames WHERE substr(payload,1,1)=X'31' GROUP BY substr(payload,3,1) ORDER BY substr(payload,3,1)",
            label: "Sync marker subtype")
        rows += try diagnosticRows(
            "SELECT hex(substr(payload,3,2)),COUNT(*) FROM frames WHERE substr(payload,1,1)=X'30' GROUP BY substr(payload,3,2) ORDER BY COUNT(*) DESC LIMIT 12",
            label: "Event ID (little endian)")
        rows += try diagnosticRows(
            "SELECT hex(payload),length(payload) FROM frames WHERE substr(payload,1,1)=X'24' AND substr(payload,3,1)=X'22' ORDER BY received DESC LIMIT 4",
            label: "Data-range response hex / bytes")
        rows += try diagnosticRows(
            "SELECT hex(payload),length(payload) FROM frames WHERE substr(payload,1,1)=X'31' AND substr(payload,3,1)=X'03' ORDER BY received DESC LIMIT 4",
            label: "Completion marker hex / bytes")
        rows += try diagnosticRows(
            "SELECT hex(payload),length(payload) FROM frames WHERE substr(payload,1,1)=X'24' AND substr(payload,3,1)=X'16' ORDER BY received DESC LIMIT 3",
            label: "History-request response hex / bytes")
        rows += try consoleEvidence()
        return rows.joined(separator: "\n")
    }
    private func consoleEvidence() throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM frames WHERE substr(payload,1,1)=X'32' ORDER BY received DESC LIMIT 20000", -1, &statement, nil) == SQLITE_OK else { throw Failure.database("Cannot read console evidence") }
        defer { sqlite3_finalize(statement) }
        var recent: [String] = []
        var relevant: [String] = []
        var seen = Set<String>()
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let pointer = sqlite3_column_blob(statement, 0) {
                let bytes = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))
                let text = Self.consoleText(bytes)
                if !text.isEmpty && seen.insert(text).inserted {
                    if recent.count < 8 { recent.append("Recent console: " + text) }
                    let lower = text.lowercased()
                    if relevant.count < 24 && ["rtc", "clock", "invalid", "saving", "crc fail", "flash", "error"].contains(where: { lower.contains($0) }) {
                        relevant.append("Clock/flash console evidence: " + text)
                    }
                }
            }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot read console evidence") }
        return relevant + recent
    }
    static func consoleText(_ bytes: [UInt8]) -> String {
        // Preserve printable runs rather than assuming a firmware-specific log header.
        var runs: [String] = []; var current: [UInt8] = []
        for byte in bytes.dropFirst(2) {
            if byte >= 32 && byte <= 126 { current.append(byte) }
            else { if current.count >= 4 { runs.append(String(decoding: current, as: UTF8.self)) }; current = [] }
        }
        if current.count >= 4 { runs.append(String(decoding: current, as: UTF8.self)) }
        return runs.joined(separator: " | ")
    }
    private func diagnosticRows(_ sql: String, label: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.database("Cannot inspect sync responses") }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows.append("\(label): \(String(cString: sqlite3_column_text(statement, 0))) · \(sqlite3_column_int(statement, 1))")
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot inspect sync responses") }
        return rows.isEmpty ? ["\(label): none saved"] : rows
    }
    func saveOptical(_ frame: [UInt8], at date: Date) throws {
        let statement = try prepare("INSERT INTO optical_frames VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        _ = frame.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(frame.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot save optical frame") }
    }
    func pruneOptical(before date: Date) throws {
        let statement = try prepare("DELETE FROM optical_frames WHERE received<?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot prune optical frames") }
    }
    func saveLiveMinute(_ minute: MinuteHR) throws {
        guard minute.count > 0, minute.average.isFinite, minute.average > 0, minute.average <= 300,
              minute.minimum > 0, minute.maximum <= 300, minute.minimum <= minute.maximum,
              minute.rmssd.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw Failure.database("Invalid live minute") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO live_minutes VALUES(?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw Failure.database("Cannot prepare minute write") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement,1,minute.minute); sqlite3_bind_double(statement,2,minute.average)
        sqlite3_bind_int(statement,3,Int32(minute.minimum)); sqlite3_bind_int(statement,4,Int32(minute.maximum)); sqlite3_bind_int64(statement,5,Int64(minute.count))
        if let rr = minute.rmssd { sqlite3_bind_double(statement,6,rr) } else { sqlite3_bind_null(statement,6) }
        if let count = minute.validRRCount { sqlite3_bind_int(statement,7,Int32(count)) } else { sqlite3_bind_null(statement,7) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot save live minute") }
    }
    func liveMinutes(from: Date, to: Date) throws -> [MinuteHR] {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite else { throw Failure.database("Invalid date range") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT * FROM live_minutes WHERE minute>=? AND minute<? ORDER BY minute",-1,&statement,nil) == SQLITE_OK else { throw Failure.database("Cannot query live minutes") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement,1,floor(from.timeIntervalSince1970/60)); sqlite3_bind_double(statement,2,ceil(to.timeIntervalSince1970/60))
        var result: [MinuteHR] = []; var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append(MinuteHR(minute: sqlite3_column_int64(statement,0),average: sqlite3_column_double(statement,1),minimum: Int(sqlite3_column_int(statement,2)),maximum: Int(sqlite3_column_int(statement,3)),count: Int(sqlite3_column_int64(statement,4)),rmssd: sqlite3_column_type(statement,5) == SQLITE_NULL ? nil : sqlite3_column_double(statement,5), validRRCount: sqlite3_column_type(statement,6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement,6))))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot query live minutes") }; return result
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
        return statement
    }
    /// Decoded history samples in `[from, to)`, oldest first.
    func samples(from: Date, to: Date) throws -> [Sample] {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite else { throw Failure.database("Invalid date range") }
        let statement = try prepare("SELECT id,time,bpm FROM samples WHERE time>=? AND time<? ORDER BY time")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970); sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        var result: [Sample] = []; var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append(Sample(id: String(cString: sqlite3_column_text(statement, 0)), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), bpm: Int(sqlite3_column_int(statement, 2))))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("History query failed") }
        return result
    }
    /// Local-day numbers (days since 1970, shifted by `tzOffset` seconds) that have any stored heart-rate data in `[from, to)`.
    func daysWithData(from: Date, to: Date, tzOffset: Int) throws -> Set<Int> {
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        guard lo.isFinite, hi.isFinite else { throw Failure.database("Invalid date range") }
        var days = Set<Int>()
        for sql in [
            "SELECT DISTINCT CAST((minute*60+?)/86400 AS INTEGER) FROM history_minutes WHERE minute>=? AND minute<?",
            "SELECT DISTINCT CAST((minute*60+?)/86400 AS INTEGER) FROM live_minutes WHERE minute>=? AND minute<?",
        ] {
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(tzOffset)); sqlite3_bind_int64(statement, 2, Int64(lo / 60)); sqlite3_bind_int64(statement, 3, Int64(hi / 60))
            while sqlite3_step(statement) == SQLITE_ROW { days.insert(Int(sqlite3_column_int64(statement, 0))) }
        }
        let statement = try prepare("SELECT DISTINCT CAST((time+?)/86400 AS INTEGER) FROM samples WHERE time>=? AND time<?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(tzOffset)); sqlite3_bind_double(statement, 2, lo); sqlite3_bind_double(statement, 3, hi)
        while sqlite3_step(statement) == SQLITE_ROW { days.insert(Int(sqlite3_column_int64(statement, 0))) }
        return days
    }
    /// Oldest stored heart-rate data of any kind.
    func earliestSampleDate() throws -> Date? {
        var oldest: Double?
        for sql in ["SELECT MIN(minute)*60.0 FROM history_minutes", "SELECT MIN(minute)*60.0 FROM live_minutes", "SELECT MIN(time) FROM samples"] {
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL {
                let value = sqlite3_column_double(statement, 0); oldest = min(oldest ?? value, value)
            }
        }
        return oldest.map { Date(timeIntervalSince1970: $0) }
    }
    /// Time of the newest decoded history sample.
    func latestSampleDate() throws -> Date? {
        let statement = try prepare("SELECT MAX(time) FROM samples")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }
    /// Insert already-decoded samples (demo data and tests). Real syncs go through `persist`.
    func insertSamples(_ samples: [Sample]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT OR IGNORE INTO samples VALUES(?,?,?)")
            defer { sqlite3_finalize(statement) }
            for sample in samples {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, sample.id, -1, Self.transient)
                sqlite3_bind_double(statement, 2, sample.date.timeIntervalSince1970); sqlite3_bind_int(statement, 3, Int32(sample.bpm))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot insert sample") }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func saveDetection(_ detection: DetectedActivity) throws {
        let payload = String(decoding: try Self.encoder.encode(detection), as: UTF8.self)
        let statement = try prepare("INSERT OR REPLACE INTO detected_activities VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, detection.id, -1, Self.transient)
        sqlite3_bind_double(statement, 2, detection.start.timeIntervalSince1970); sqlite3_bind_double(statement, 3, detection.end.timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, detection.status.rawValue, -1, Self.transient); sqlite3_bind_text(statement, 5, payload, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot save detection") }
    }
    /// Detections of every status that end after `since`, oldest first.
    func detections(since: Date) throws -> [DetectedActivity] {
        let statement = try prepare("SELECT payload FROM detected_activities WHERE end>=? ORDER BY start")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        var result: [DetectedActivity] = []; var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0), let value = try? Self.decoder.decode(DetectedActivity.self, from: Data(String(cString: text).utf8)) { result.append(value) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot query detections") }
        return result
    }
    /// `wakeDay` is the local calendar day the night ended on, as days since 1970.
    func saveSleep(_ session: SleepSession, wakeDay: Int) throws {
        let payload = String(decoding: try Self.encoder.encode(session), as: UTF8.self)
        let statement = try prepare("INSERT OR REPLACE INTO sleeps VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(wakeDay)); sqlite3_bind_text(statement, 2, payload, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot save sleep") }
    }
    /// Stored nights with `wakeDay` in `[from, to]`, oldest first.
    func sleeps(fromDay: Int, toDay: Int) throws -> [(wakeDay: Int, session: SleepSession)] {
        let statement = try prepare("SELECT wake_day,payload FROM sleeps WHERE wake_day>=? AND wake_day<=? ORDER BY wake_day")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(fromDay)); sqlite3_bind_int64(statement, 2, Int64(toDay))
        var result: [(wakeDay: Int, session: SleepSession)] = []; var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1), let value = try? Self.decoder.decode(SleepSession.self, from: Data(String(cString: text).utf8)) {
                result.append((Int(sqlite3_column_int64(statement, 0)), value))
            }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot query sleeps") }
        return result
    }
    func document<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        let statement = try prepare("SELECT payload FROM health_documents WHERE key=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement,1,key,-1,Self.transient)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(statement,0) else { throw Failure.database("Cannot read health document") }
        return try Self.decoder.decode(type, from: Data(bytes: pointer,count: Int(sqlite3_column_bytes(statement,0))))
    }
    func saveDocument<T: Encodable>(_ value: T, key: String) throws {
        let data = try Self.encoder.encode(value)
        let statement = try prepare("INSERT OR REPLACE INTO health_documents VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement,1,key,-1,Self.transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement,2,$0.baseAddress,Int32(data.count),Self.transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot save health document") }
    }
    func saveRevision<T: Encodable>(_ value: T, key: String) throws {
        let data = try Self.encoder.encode(value)
        let statement = try prepare("INSERT INTO metric_revisions(key,payload,created) SELECT ?,?,? WHERE NOT EXISTS(SELECT 1 FROM metric_revisions WHERE id=(SELECT MAX(id) FROM metric_revisions WHERE key=?) AND payload=?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement,1,key,-1,Self.transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement,2,$0.baseAddress,Int32(data.count),Self.transient) }
        sqlite3_bind_double(statement,3,Date().timeIntervalSince1970)
        sqlite3_bind_text(statement,4,key,-1,Self.transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement,5,$0.baseAddress,Int32(data.count),Self.transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("Cannot save metric revision") }
    }
    func metricRevisions() throws -> [String] {
        let statement = try prepare("SELECT payload FROM metric_revisions ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []; var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let pointer = sqlite3_column_blob(statement,0) { result.append(String(decoding: Data(bytes: pointer,count: Int(sqlite3_column_bytes(statement,0))),as: UTF8.self)) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("Cannot export revisions") }
        return result
    }
    /// Remove everything this store holds. The schema stays, so the app can keep running and start filling it again.
    func eraseAll() throws {
        try execute("DELETE FROM frames; DELETE FROM samples; DELETE FROM live_minutes; DELETE FROM history_minutes; DELETE FROM records; DELETE FROM detected_activities; DELETE FROM sleeps; DELETE FROM health_documents; DELETE FROM metric_revisions; DELETE FROM sync_cursors; DELETE FROM optical_frames;")
        try? execute("VACUUM;")
    }
    func recent() throws -> [Sample] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,time,bpm FROM (SELECT * FROM samples ORDER BY time DESC LIMIT 2000) ORDER BY time", -1, &statement, nil) == SQLITE_OK else { throw Failure.database("Cannot query history") }
        defer { sqlite3_finalize(statement) }
        var result: [Sample] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append(Sample(id: String(cString: sqlite3_column_text(statement, 0)), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), bpm: Int(sqlite3_column_int(statement, 2))))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure.database("History query failed") }
        return result
    }
}
