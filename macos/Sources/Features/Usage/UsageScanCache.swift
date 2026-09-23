import Foundation

/// The parsed records of one transcript file.
///
/// Transcripts are append-only, and a file that hasn't changed can't yield different
/// usage, so records are cached by file and reused while its size and modification time
/// are the same. Caching by file rather than by day doesn't depend on the time zone, and
/// keeps de-duplication across files exact.
struct UsageCachedTranscript: Equatable {
    var size: Int
    var mtimeNs: Int
    var provider: UsageProvider

    /// Records from newline-terminated lines, up to `position.resumeOffset`.
    var records: [UsageRecord]

    /// Records from a last line that wasn't terminated when the file was read. See
    /// `UsageParseResult.tailRecords`.
    var tailRecords: [UsageRecord]

    var position: UsageParsePosition

    var mtimeMs: Int { mtimeNs / 1_000_000 }

    var allRecords: [UsageRecord] {
        tailRecords.isEmpty ? records : records + tailRecords
    }
}

/// Saves the transcript cache to disk, so relaunching doesn't re-read every transcript,
/// and usage survives agents deleting old transcripts (Claude Code does after 30 days).
///
/// Records are stored as positional rows with the model and session strings interned.
enum UsageScanCache {
    private static let version = 1

    /// Keeps only the first record of each key, within one file. Callers stitching a
    /// resumed parse together pass one `seen` set across its parts.
    static func dedupeWithinFile(_ records: [UsageRecord], seen: inout Set<String>) -> [UsageRecord] {
        records.filter { record in
            guard let key = record.dedupeKey else { return true }
            return seen.insert(key).inserted
        }
    }

    static func encode(_ cache: [String: UsageCachedTranscript]) -> Data? {
        var models: [String] = []
        var sessions: [String] = []
        var modelIndex: [String: Int] = [:]
        var sessionIndex: [String: Int] = [:]

        func intern(_ value: String, _ table: inout [String], _ index: inout [String: Int]) -> Int {
            if let existing = index[value] { return existing }
            table.append(value)
            index[value] = table.count - 1
            return table.count - 1
        }

        func row(_ record: UsageRecord) -> [Any] {
            [
                record.timestampMs,
                intern(record.model, &models, &modelIndex),
                intern(record.sessionId, &sessions, &sessionIndex),
                record.totals.uncachedInput,
                record.totals.cachedInput,
                record.totals.cacheCreation,
                record.totals.output,
                record.totals.reasoning,
                record.dedupeKey ?? NSNull(),
                record.reportedCostUsd ?? NSNull(),
            ]
        }

        var files: [String: Any] = [:]
        for (path, entry) in cache {
            let file: [String: Any] = [
                "s": entry.size,
                "m": entry.mtimeNs,
                "p": entry.provider.rawValue,
                "r": entry.records.map(row),
                "t": entry.tailRecords.map(row),
                "o": entry.position.resumeOffset,
                "gl": entry.position.guardLength,
                "gh": Int(entry.position.guardHash),
            ]
            files[path] = file
        }

        let document: [String: Any] = [
            "version": version,
            "models": models,
            "sessions": sessions,
            "files": files,
        ]
        return try? JSONSerialization.data(withJSONObject: document)
    }

    /// Rebuilds the cache. Anything malformed is dropped: a corrupt cache should cost one
    /// full scan, never wrong totals.
    static func decode(_ data: Data) -> [String: UsageCachedTranscript] {
        guard let document = UsageJSON.object(data),
              document["version"] as? Int == version,
              let models = document["models"] as? [String],
              let sessions = document["sessions"] as? [String],
              let files = document["files"] as? [String: Any] else { return [:] }

        // Any corrupt row drops the whole file. Keeping the rest under the same size and
        // modification time would look like a valid entry and never be read again.
        func decodeRecords(_ value: Any?, _ provider: UsageProvider) -> [UsageRecord]? {
            guard let rows = value as? [[Any]] else { return nil }
            var records: [UsageRecord] = []
            records.reserveCapacity(rows.count)
            for row in rows {
                guard row.count == 10,
                      let timestampMs = row[0] as? Int,
                      let modelIndex = row[1] as? Int, models.indices.contains(modelIndex),
                      let sessionIndex = row[2] as? Int, sessions.indices.contains(sessionIndex),
                      let uncachedInput = row[3] as? Int,
                      let cachedInput = row[4] as? Int,
                      let cacheCreation = row[5] as? Int,
                      let output = row[6] as? Int,
                      let reasoning = row[7] as? Int else { return nil }
                records.append(UsageRecord(
                    provider: provider,
                    timestampMs: timestampMs,
                    model: models[modelIndex],
                    sessionId: sessions[sessionIndex],
                    totals: UsageTokenTotals(
                        uncachedInput: uncachedInput,
                        cachedInput: cachedInput,
                        cacheCreation: cacheCreation,
                        output: output,
                        reasoning: reasoning),
                    reportedCostUsd: UsageJSON.number(row[9]),
                    dedupeKey: row[8] as? String))
            }
            return records
        }

        var cache: [String: UsageCachedTranscript] = [:]
        for (path, value) in files {
            guard let file = value as? [String: Any],
                  let size = file["s"] as? Int,
                  let mtimeNs = file["m"] as? Int,
                  let provider = (file["p"] as? String).flatMap(UsageProvider.init(rawValue:)),
                  let resumeOffset = file["o"] as? Int,
                  let guardLength = file["gl"] as? Int,
                  let guardHash = (file["gh"] as? Int).flatMap(UInt32.init(exactly:)),
                  let records = decodeRecords(file["r"], provider),
                  let tailRecords = decodeRecords(file["t"], provider) else { continue }

            cache[path] = UsageCachedTranscript(
                size: size,
                mtimeNs: mtimeNs,
                provider: provider,
                records: records,
                tailRecords: tailRecords,
                position: UsageParsePosition(
                    resumeOffset: resumeOffset,
                    guardLength: guardLength,
                    guardHash: guardHash))
        }
        return cache
    }
}
