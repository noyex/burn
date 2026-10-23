import Foundation
import SQLite3

/// Resolves the service tier of Codex turns whose rollout carried no `thread_settings_applied`, from T3 Code's own
/// database (`CodexUsageHistory.resolve`). Read-only; returns nothing when T3's database is missing or unreadable.
enum CodexTierResolver {
    struct Request: Hashable, Sendable {
        let session, turn, model: String
    }

    static var dbPath: String { NSHomeDirectory() + "/.t3/userdata/statev2.sqlite" }

    /// Size and mtime of T3's database; changes when T3 recorded anything new.
    static func dbStamp() -> String {
        [dbPath].map { p -> String in
            var st = stat()
            return stat(p, &st) == 0 ? "\(st.st_size).\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)" : "none"
        }.joined(separator: "|")
    }

    static func resolve(_ requests: [Request]) -> [Request: Speed] {
        guard !requests.isEmpty, FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let turnIds = Array(Set(requests.map(\.turn)))
        guard let json = try? JSONSerialization.data(withJSONObject: turnIds), let jsonText = String(data: json, encoding: .utf8)
        else { return [:] }
        let sql = """
        SELECT json_extract(attempt.payload_json, '$.nativeThreadId') AS native_thread_id,
          json_extract(turn.payload_json, '$.nativeTurnRef.nativeId') AS native_turn_id,
          (
            SELECT json_extract(event.payload_json, '$.modelSelection')
            FROM orchestration_events AS event
            WHERE event.aggregate_kind = 'thread'
              AND event.application_event_version = 2
              AND event.stream_id = attempt.thread_id
              AND event.event_type = 'run.updated'
              AND json_extract(event.payload_json, '$.id') = attempt.run_id
              AND json_extract(event.payload_json, '$.activeAttemptId') = attempt.attempt_id
              AND json_extract(event.payload_json, '$.status') = 'running'
            ORDER BY event.sequence
            LIMIT 1
          ) AS selection_json
        FROM orchestration_v2_projection_provider_turns AS turn
        LEFT JOIN orchestration_v2_projection_run_attempts AS attempt
          ON attempt.attempt_id = turn.run_attempt_id
          AND attempt.thread_id = turn.thread_id
          AND attempt.provider_thread_id = turn.provider_thread_id
        WHERE json_extract(turn.payload_json, '$.nativeTurnRef.driver') = 'codex'
          AND json_extract(turn.payload_json, '$.nativeTurnRef.nativeId') IN (SELECT value FROM json_each(?))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt!, 1, jsonText)

        struct Match { let thread: String?; let selection: String? }
        var byTurn: [String: Match?] = [:]   // nil value: the turn id is ambiguous
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return [:] }
            guard let turn = text(1) else { continue }
            byTurn[turn] = byTurn[turn] != nil ? .some(nil) : .some(Match(thread: text(0), selection: text(2)))
        }

        var out: [Request: Speed] = [:]
        for r in requests {
            guard let m = byTurn[r.turn] ?? nil, m.thread == r.session,
                  let sel = m.selection.flatMap({ $0.data(using: .utf8) })
                      .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  sel["model"] as? String == r.model else { continue }
            let options = sel["options"] as? [[String: Any]] ?? []
            if options.contains(where: { $0["id"] as? String == "serviceTier" && !($0["value"] is String) }) { continue }
            var tier = options.first { $0["id"] as? String == "serviceTier" }?["value"] as? String
            if tier == nil, let n = options.first(where: { $0["id"] as? String == "fastMode" })?["value"] as? NSNumber,
               CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue { tier = "fast" }
            switch tier {
            case "fast", "priority": out[r] = .fast
            case "ultrafast": out[r] = .ultrafast
            case nil, "default", "standard": out[r] = .standard
            default: break
            }
        }
        return out
    }
}
