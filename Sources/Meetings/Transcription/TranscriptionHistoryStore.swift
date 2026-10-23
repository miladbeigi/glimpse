import Foundation
import SQLite3

enum TranscriptionStatus: String, Codable, Sendable {
    case pending, processing, completed, failed
}

struct PipelineTimings: Codable, Sendable, Equatable {
    var transcription: Double?
    var diarization: Double?
    var fileSaving: Double?
    var totalEndToEnd: Double?
}

struct TranscriptionRecord: Identifiable, Equatable, Sendable {
    var id: Int64
    var meetingId: String?
    var meetingTitle: String
    var meetingDate: Date
    var attendees: [String]
    var transcriptionStartedAt: Date?
    var transcriptionFinishedAt: Date?
    var status: TranscriptionStatus
    var currentStep: String?
    var wavFilePath: String?
    var markdownFilePath: String?
    var segmentCount: Int?
    var durationSeconds: Double?
    var timings: PipelineTimings
    var createdEmbeddings: [String]
}

extension Notification.Name {
    /// userInfo: "recordId": Int64, "step": String, "fraction": Double
    static let transcriptionProgress = Notification.Name("glimpse.meetings.transcriptionProgress")
    static let transcriptionHistoryChanged = Notification.Name("glimpse.meetings.transcriptionHistoryChanged")
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed transcription history. All access is serialized on one queue.
final class TranscriptionHistoryStore: @unchecked Sendable {
    static let shared = TranscriptionHistoryStore(path: Paths.historyDatabase)
    static let maxRecords = 500

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "glimpse.meetings.history")

    init(path: URL) {
        queue.sync {
            if sqlite3_open(path.path, &db) != SQLITE_OK {
                log("❌ Could not open history database at \(path.path)")
                db = nil
                return
            }
            exec("""
                CREATE TABLE IF NOT EXISTS transcriptions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id TEXT,
                    meeting_title TEXT NOT NULL,
                    meeting_date REAL NOT NULL,
                    attendees TEXT,
                    transcription_started_at REAL,
                    transcription_finished_at REAL,
                    status TEXT NOT NULL,
                    current_step TEXT,
                    wav_file_path TEXT,
                    markdown_file_path TEXT,
                    segment_count INTEGER,
                    duration_seconds REAL,
                    timing_transcription REAL,
                    timing_diarization REAL,
                    timing_file_saving REAL,
                    timing_total_end_to_end REAL,
                    created_embeddings TEXT
                );
                """)
            exec("CREATE INDEX IF NOT EXISTS idx_transcriptions_date ON transcriptions(meeting_date);")
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writes

    func startRecord(meeting: Meeting, wavPath: String?) -> Int64 {
        let id: Int64 = queue.sync {
            run("""
                INSERT INTO transcriptions (meeting_id, meeting_title, meeting_date, attendees, transcription_started_at, status, current_step, wav_file_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [meeting.id, meeting.title, meeting.start.timeIntervalSince1970, jsonString(meeting.attendees),
                      Date().timeIntervalSince1970, TranscriptionStatus.pending.rawValue, "Preparing…", wavPath])
            return sqlite3_last_insert_rowid(db)
        }
        cleanup()
        notifyChanged()
        return id
    }

    func setWavPath(_ id: Int64, path: String) {
        queue.sync { run("UPDATE transcriptions SET wav_file_path = ? WHERE id = ?", [path, id]) }
    }

    func restart(_ id: Int64) {
        queue.sync {
            run("UPDATE transcriptions SET status = ?, current_step = ?, transcription_started_at = ?, transcription_finished_at = NULL WHERE id = ?",
                [TranscriptionStatus.pending.rawValue, "Preparing…", Date().timeIntervalSince1970, id])
        }
        notifyChanged()
    }

    /// Record a progress step and broadcast it to the processing card.
    func updateProgress(_ id: Int64, step: String, fraction: Double) {
        queue.sync {
            run("UPDATE transcriptions SET status = ?, current_step = ? WHERE id = ?", [TranscriptionStatus.processing.rawValue, step, id])
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .transcriptionProgress, object: nil,
                                            userInfo: ["recordId": id, "step": step, "fraction": fraction])
        }
    }

    func complete(_ id: Int64, markdownPath: String, segmentCount: Int, duration: Double, timings: PipelineTimings, createdEmbeddings: [String]) {
        queue.sync {
            run("""
                UPDATE transcriptions SET status = ?, current_step = ?, transcription_finished_at = ?, markdown_file_path = ?,
                segment_count = ?, duration_seconds = ?, timing_transcription = ?, timing_diarization = ?, timing_file_saving = ?,
                timing_total_end_to_end = ?, created_embeddings = ? WHERE id = ?
                """, [TranscriptionStatus.completed.rawValue, "Completed", Date().timeIntervalSince1970, markdownPath, segmentCount, duration,
                      timings.transcription, timings.diarization, timings.fileSaving, timings.totalEndToEnd,
                      jsonString(createdEmbeddings), id])
        }
        notifyChanged()
    }

    func fail(_ id: Int64, error: String, duration: Double? = nil) {
        queue.sync {
            run("UPDATE transcriptions SET status = ?, current_step = ?, transcription_finished_at = ?, duration_seconds = COALESCE(?, duration_seconds) WHERE id = ?",
                [TranscriptionStatus.failed.rawValue, error, Date().timeIntervalSince1970, duration, id])
        }
        notifyChanged()
    }

    func updateAttendees(_ id: Int64, attendees: [String]) {
        queue.sync { run("UPDATE transcriptions SET attendees = ? WHERE id = ?", [jsonString(attendees), id]) }
        notifyChanged()
    }

    func updateMeetingAssignment(_ id: Int64, meetingId: String, title: String, attendees: [String]) {
        queue.sync {
            run("UPDATE transcriptions SET meeting_id = ?, meeting_title = ?, attendees = ? WHERE id = ?",
                [meetingId, title, jsonString(attendees), id])
        }
        notifyChanged()
    }

    func removeCreatedEmbedding(_ id: Int64, name: String) {
        guard var record = record(id) else { return }
        record.createdEmbeddings.removeAll { $0 == name }
        queue.sync { run("UPDATE transcriptions SET created_embeddings = ? WHERE id = ?", [jsonString(record.createdEmbeddings), id]) }
        notifyChanged()
    }

    /// Remove records (History: Delete). The caller disposes of their files.
    func delete(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            for id in ids { run("DELETE FROM transcriptions WHERE id = ?", [id]) }
        }
        notifyChanged()
    }

    /// FIFO cleanup beyond `maxRecords`, never touching in-progress records.
    func cleanup() {
        queue.sync {
            run("""
                DELETE FROM transcriptions WHERE id IN (
                    SELECT id FROM transcriptions WHERE status IN ('completed', 'failed')
                    ORDER BY meeting_date ASC
                    LIMIT MAX(0, (SELECT COUNT(*) FROM transcriptions) - ?)
                )
                """, [Self.maxRecords])
        }
    }

    // MARK: - Reads

    func all() -> [TranscriptionRecord] {
        queue.sync { query("SELECT * FROM transcriptions ORDER BY meeting_date DESC, id DESC", []) }
    }

    func record(_ id: Int64) -> TranscriptionRecord? {
        queue.sync { query("SELECT * FROM transcriptions WHERE id = ?", [id]).first }
    }

    /// Pending/processing records (candidates for startup retry).
    func incomplete() -> [TranscriptionRecord] {
        queue.sync { query("SELECT * FROM transcriptions WHERE status IN ('pending', 'processing') ORDER BY id ASC", []) }
    }

    /// All attendee names ever seen (for autocomplete).
    func knownAttendees() -> [String] {
        Array(Set(all().flatMap(\.attendees))).sorted()
    }

    // MARK: - SQLite helpers (call on `queue`)

    private func columnExists(_ name: String) -> Bool {
        guard let stmt = prepare("PRAGMA table_info(transcriptions)", []) else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == name { return true }
        }
        return false
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            log("❌ SQLite: \(err.map { String(cString: $0) } ?? "unknown error")")
            sqlite3_free(err)
        }
    }

    private func prepare(_ sql: String, _ params: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("❌ SQLite prepare: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [Any?]) {
        guard let stmt = prepare(sql, params) else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            log("❌ SQLite step: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func query(_ sql: String, _ params: [Any?]) -> [TranscriptionRecord] {
        guard let stmt = prepare(sql, params) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            columns[String(cString: sqlite3_column_name(stmt, i))] = i
        }
        func text(_ name: String) -> String? {
            guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func double(_ name: String) -> Double? {
            guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(stmt, i)
        }
        func int(_ name: String) -> Int64? {
            guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(stmt, i)
        }

        var records: [TranscriptionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(TranscriptionRecord(
                id: int("id") ?? 0,
                meetingId: text("meeting_id"),
                meetingTitle: text("meeting_title") ?? "Meeting",
                meetingDate: Date(timeIntervalSince1970: double("meeting_date") ?? 0),
                attendees: decodeStrings(text("attendees")),
                transcriptionStartedAt: double("transcription_started_at").map(Date.init(timeIntervalSince1970:)),
                transcriptionFinishedAt: double("transcription_finished_at").map(Date.init(timeIntervalSince1970:)),
                status: TranscriptionStatus(rawValue: text("status") ?? "") ?? .failed,
                currentStep: text("current_step"),
                wavFilePath: text("wav_file_path"),
                markdownFilePath: text("markdown_file_path"),
                segmentCount: int("segment_count").map(Int.init),
                durationSeconds: double("duration_seconds"),
                timings: PipelineTimings(
                    transcription: double("timing_transcription"),
                    diarization: double("timing_diarization"),
                    fileSaving: double("timing_file_saving"),
                    totalEndToEnd: double("timing_total_end_to_end")),
                createdEmbeddings: decodeStrings(text("created_embeddings"))))
        }
        return records
    }

    private func jsonString(_ strings: [String]) -> String {
        (try? String(data: JSONEncoder().encode(strings), encoding: .utf8)) ?? "[]"
    }

    private func decodeStrings(_ s: String?) -> [String] {
        guard let s, let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .transcriptionHistoryChanged, object: nil)
        }
    }
}
