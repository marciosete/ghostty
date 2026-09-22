import Foundation

/// The usage of one window, priced and bucketed.
struct UsageReport {
    let window: UsageWindow
    let buckets: [UsageBucket]

    /// Distinct sessions with usage in the window. Sessions span days and models, so they
    /// are counted per transcript directory rather than summed from buckets.
    let sessionsByProvider: [UsageProvider: Int]

    let pricing: UsagePricingStatus
    let scanDuration: TimeInterval
}

/// Where the model rates behind a report came from.
struct UsagePricingStatus: Equatable {
    enum Source: Equatable {
        /// Downloaded within the last day.
        case fresh

        /// A saved copy, because a download failed or wasn't due.
        case cached

        /// No rates at all, so every model is unpriced.
        case unavailable
    }

    let source: Source
    let fetchedAt: Date?
    let knownModels: Int
}

/// Scans the coding agents' session transcripts and prices their usage, like ccusage
/// does. It reads the agents' own files rather than anything Ghostty records, so usage
/// covers sessions run anywhere on this Mac.
///
/// One scanner serves the whole app, and scans run one at a time on its queue. Parsed
/// files are cached by size and modification time, and a file that only grew is read
/// from where the last scan stopped, so a scan after the first only reads new bytes.
final class UsageScanner {
    static let shared = UsageScanner()

    private static let ratesURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    /// Rates change rarely. A day old table keeps the panel working offline.
    private static let ratesMaxAge: TimeInterval = 24 * 60 * 60

    /// An explicit refresh downloads the rates again, unless they are this recent.
    private static let ratesRefreshFloor: TimeInterval = 60

    /// The longest window the panel offers. Cached files older than this are dropped.
    private static let retentionMs = 90 * UsageWindow.dayMs

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.usage-scanner", qos: .userInitiated)
    private let storageDirectory: URL

    // Only touched on `queue`.
    private var cache: [String: UsageCachedTranscript] = [:]
    private var cacheLoaded = false
    private var cacheDirty = false
    private var rates = UsageRateTable()
    private var ratesFetchedAt: Date?
    private var ratesSource: UsagePricingStatus.Source = .unavailable

    init(storageDirectory: URL = UsageScanner.defaultStorageDirectory) {
        self.storageDirectory = storageDirectory
    }

    static var defaultStorageDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("Usage", isDirectory: true)
    }

    private var cacheURL: URL { storageDirectory.appendingPathComponent("transcripts.json") }
    private var ratesURL: URL { storageDirectory.appendingPathComponent("model-rates.json") }

    /// Scans `window` in the background and calls `completion` on the main queue.
    /// `refreshRates` downloads the model rates even if they're less than a day old, so a
    /// model added to the table since gets a price.
    func scan(_ window: UsageWindow, refreshRates: Bool = false, completion: @escaping (UsageReport) -> Void) {
        queue.async {
            let report = self.performScan(window, refreshRates: refreshRates)
            DispatchQueue.main.async { completion(report) }
        }
    }

    // MARK: Scanning

    /// A directory of transcripts of one provider.
    private struct Source: Hashable {
        let provider: UsageProvider
        let directory: String

        /// When set, only files with this name are read.
        let fileName: String?
    }

    /// The transcript directories, from the same environment variables the agents read.
    /// An app opened from the Dock doesn't see the variables of a shell profile, so the
    /// default homes are what usually applies.
    private func sources() -> [Source] {
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory() as NSString

        func configured(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                return nil
            }
            return (value as NSString).expandingTildeInPath
        }

        var sources: [Source] = []
        if let claudeHome = configured("CLAUDE_CONFIG_DIR") {
            sources.append(Source(provider: .claude, directory: claudeHome + "/projects", fileName: nil))
        } else {
            // Recent Claude Code versions can keep their data under ~/.config/claude.
            sources.append(Source(provider: .claude, directory: home.appendingPathComponent(".config/claude/projects"), fileName: nil))
            sources.append(Source(provider: .claude, directory: home.appendingPathComponent(".claude/projects"), fileName: nil))
        }

        let codexHome = configured("CODEX_HOME") ?? home.appendingPathComponent(".codex")
        sources.append(Source(provider: .codex, directory: codexHome + "/sessions", fileName: nil))

        let grokHome = configured("GROK_HOME") ?? home.appendingPathComponent(".grok")
        sources.append(Source(provider: .grok, directory: grokHome + "/sessions", fileName: "updates.jsonl"))

        // Two paths to the same directory would count its usage twice.
        var seen: Set<Source> = []
        return sources.compactMap { source in
            let resolved = Source(
                provider: source.provider,
                directory: (source.directory as NSString).resolvingSymlinksInPath,
                fileName: source.fileName)
            return seen.insert(resolved).inserted ? resolved : nil
        }
    }

    private func performScan(_ window: UsageWindow, refreshRates: Bool) -> UsageReport {
        let startedAt = Date()
        let nowMs = Int(startedAt.timeIntervalSince1970 * 1000)
        let retentionCutoffMs = nowMs - Self.retentionMs
        loadCacheIfNeeded()

        // Rates only matter once records are aggregated, so they download while the
        // transcripts are read rather than holding them up.
        let ratesDownload = startRatesLoad(force: refreshRates)

        let sources = self.sources()
        var filesBySource: [Source: [(path: String, records: [UsageRecord])]] = [:]
        for source in sources {
            let files = UsageTranscriptReader.listFiles(
                in: source.directory,
                modifiedSinceMs: window.earliestRelevantModificationMs,
                fileName: source.fileName)
            filesBySource[source] = files.map { ($0.path, records(of: $0, provider: source.provider)) }
        }

        if let ratesDownload {
            finishRatesLoad(ratesDownload)
        }

        let aggregator = UsageAggregator(window: window, rates: rates)
        var sessionsByProvider: [UsageProvider: Int] = [:]
        for source in sources {
            var files = filesBySource[source] ?? []

            // Agents delete old transcripts, but the usage already read from them still
            // counts until it's older than the longest window.
            let livePaths = Set(files.map(\.path))
            let prefix = source.directory.hasSuffix("/") ? source.directory : source.directory + "/"
            for (path, entry) in cache
            where entry.provider == source.provider
                && entry.mtimeMs >= retentionCutoffMs
                && !livePaths.contains(path)
                && path.hasPrefix(prefix) {
                files.append((path, entry.allRecords))
            }

            var sessions: Set<String> = []
            for file in files {
                var codexOccurrences: [String: Int] = [:]
                for var record in file.records {
                    if record.provider == .codex, !record.sessionId.isEmpty {
                        // A rollout moved to another folder is counted once, without
                        // merging repeated identical events within one rollout
                        // (timestamps can have only second precision).
                        let totals = record.totals
                        let key = "\(record.sessionId)\u{0}\(record.timestampMs)\u{0}\(record.model)\u{0}"
                            + "\(totals.uncachedInput),\(totals.cachedInput),\(totals.cacheCreation),\(totals.output),\(totals.reasoning)"
                        let occurrence = (codexOccurrences[key] ?? 0) + 1
                        codexOccurrences[key] = occurrence
                        record.dedupeKey = "codex\u{0}\(key):\(occurrence)"
                    }

                    // Only sessions with usage in the window count. The modification
                    // time slack lets in files whose records fall outside it.
                    if aggregator.add(record), !record.sessionId.isEmpty {
                        sessions.insert(record.sessionId)
                    }
                }
            }
            sessionsByProvider[source.provider, default: 0] += sessions.count
        }

        let expired = cache.filter { $0.value.mtimeMs < retentionCutoffMs }.map(\.key)
        if !expired.isEmpty {
            expired.forEach { cache.removeValue(forKey: $0) }
            cacheDirty = true
        }
        saveCacheIfNeeded()

        return UsageReport(
            window: window,
            buckets: aggregator.finish(),
            sessionsByProvider: sessionsByProvider,
            pricing: UsagePricingStatus(source: ratesSource, fetchedAt: ratesFetchedAt, knownModels: rates.count),
            scanDuration: Date().timeIntervalSince(startedAt))
    }

    /// The records of one transcript, reusing the cached parse when the file hasn't
    /// changed and reading only the appended bytes when it grew.
    private func records(of file: UsageTranscriptFile, provider: UsageProvider) -> [UsageRecord] {
        // The provider is part of the identity: a file parsed by another provider's parser
        // can't be reused.
        let cached = cache[file.path].flatMap { $0.provider == provider ? $0 : nil }
        if let cached, cached.size == file.size, cached.mtimeNs == file.mtimeNs {
            return cached.allRecords
        }

        // Only a file that strictly grew may resume. The same size with a new time, or a
        // smaller file, means it was rewritten.
        let resume = cached.flatMap { file.size > $0.size ? $0.position : nil }
        guard let parsed = UsageTranscriptReader.read(path: file.path, provider: provider, resumingFrom: resume) else {
            return cached?.allRecords ?? []
        }

        // Stored de-duplicated within the file, which removes almost all duplicates. The
        // aggregator still de-duplicates across files.
        var seen: Set<String> = []
        let base = parsed.resumed ? cached?.records ?? [] : []
        let records = UsageScanCache.dedupeWithinFile(base + parsed.records, seen: &seen)
        let tailRecords = UsageScanCache.dedupeWithinFile(parsed.tailRecords, seen: &seen)

        let entry = UsageCachedTranscript(
            size: file.size,
            mtimeNs: file.mtimeNs,
            provider: provider,
            records: records,
            tailRecords: tailRecords,
            position: parsed.position)
        cache[file.path] = entry
        cacheDirty = true
        return entry.allRecords
    }

    // MARK: Transcript Cache

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let data = try? Data(contentsOf: cacheURL) {
            cache = UsageScanCache.decode(data)
        }
    }

    private func saveCacheIfNeeded() {
        // A cache that can't be saved means a slower next launch, not a failed scan. It
        // stays dirty so the next scan tries again.
        guard cacheDirty, let data = UsageScanCache.encode(cache) else { return }
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            cacheDirty = false
        } catch {
            return
        }
    }

    // MARK: Model Rates

    /// Loads the saved rates the first time, and starts a download when they are older
    /// than a day (or than a minute, for an explicit refresh). Without any rates, every
    /// model reports as unpriced rather than the scan failing.
    private func startRatesLoad(force: Bool) -> RatesDownload? {
        let now = Date()
        let maxAge = force ? Self.ratesRefreshFloor : Self.ratesMaxAge
        if let ratesFetchedAt, now.timeIntervalSince(ratesFetchedAt) < maxAge { return nil }

        if ratesFetchedAt == nil,
           let data = try? Data(contentsOf: ratesURL),
           let document = try? JSONSerialization.jsonObject(with: data),
           let savedAt = (try? FileManager.default.attributesOfItem(atPath: ratesURL.path))?[.modificationDate] as? Date {
            let table = UsageRateTable(liteLLM: document)
            if table.count > 0 {
                rates = table
                ratesFetchedAt = savedAt
                ratesSource = .cached
                if now.timeIntervalSince(savedAt) < maxAge { return nil }
            }
        }

        return RatesDownload(url: Self.ratesURL)
    }

    private func finishRatesLoad(_ download: RatesDownload) {
        guard let data = download.wait(),
              let document = try? JSONSerialization.jsonObject(with: data) else {
            // What's being served is past its age now and must not claim to be fresh.
            if rates.count > 0 { ratesSource = .cached }
            return
        }

        let table = UsageRateTable(liteLLM: document)
        guard table.count > 0 else { return }
        rates = table
        ratesFetchedAt = Date()
        ratesSource = .fresh

        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? data.write(to: ratesURL, options: .atomic)
    }
}

/// A download of the rate table that the scanner's queue waits on.
private final class RatesDownload {
    private let semaphore = DispatchSemaphore(value: 0)
    private var data: Data?

    init(url: URL) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        URLSession.shared.dataTask(with: request) { [self] data, response, _ in
            if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                self.data = data
            }
            semaphore.signal()
        }.resume()
    }

    func wait() -> Data? {
        semaphore.wait()
        return data
    }
}
