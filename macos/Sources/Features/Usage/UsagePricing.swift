import Foundation

/// The rates of one model, in USD per token.
struct UsageModelRate: Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheCreation: Double

    /// The cost of `totals` at these rates. Reasoning tokens are already in `output`.
    func cost(of totals: UsageTokenTotals) -> Double {
        Double(totals.uncachedInput) * input
            + Double(totals.cachedInput) * cacheRead
            + Double(totals.cacheCreation) * cacheCreation
            + Double(totals.output) * output
    }

    /// What the cached input would have cost at the full input rate, minus what it cost.
    func cacheSavings(of totals: UsageTokenTotals) -> Double {
        Double(totals.cachedInput) * (input - cacheRead)
    }
}

/// Model rates from LiteLLM's `model_prices_and_context_window.json`, the same table
/// ccusage prices against.
///
/// LiteLLM also publishes tiered rates (long context, flex, priority, batch). Transcripts
/// don't record which tier served a request, so everything is priced at the base tier.
struct UsageRateTable {
    private var rates: [String: UsageModelRate] = [:]

    var count: Int { rates.count }

    init() {}

    /// Builds the table from the LiteLLM document. Entries without both an input and an
    /// output rate are dropped: a half priced model would quietly under-report cost,
    /// which is worse than reporting it as unpriced.
    ///
    /// Entries keep their full name. A bare name (without a `provider/` prefix) is added
    /// as an alias only when no entry has that name and every entry it could stand for
    /// has the same rate.
    init(liteLLM document: Any) {
        guard let entries = document as? [String: Any] else { return }

        for name in entries.keys.sorted() {
            guard let entry = entries[name] as? [String: Any],
                  let input = UsageJSON.number(entry["input_cost_per_token"]),
                  let output = UsageJSON.number(entry["output_cost_per_token"]) else { continue }

            let key = Self.normalize(name)
            guard !key.isEmpty else { continue }

            // Anthropic bills cache reads at a discount and cache writes at a premium.
            // When a model has neither, cached input is priced as input, not as free.
            rates[key] = UsageModelRate(
                input: input,
                output: output,
                cacheRead: UsageJSON.number(entry["cache_read_input_token_cost"]) ?? input,
                cacheCreation: UsageJSON.number(entry["cache_creation_input_token_cost"]) ?? input)
        }

        var aliases: [String: UsageModelRate] = [:]
        var conflicting: Set<String> = []
        for (key, rate) in rates {
            let alias = Self.bareName(key)
            guard !alias.isEmpty, alias != key, rates[alias] == nil else { continue }
            if let held = aliases[alias] {
                if held != rate { conflicting.insert(alias) }
            } else {
                aliases[alias] = rate
            }
        }
        for (alias, rate) in aliases where !conflicting.contains(alias) {
            rates[alias] = rate
        }
    }

    /// Models that are never priced. `<synthetic>` marks messages Claude Code made up
    /// locally, which were never billed. Bare family names are ambiguous across
    /// generations, so they are reported as unpriced rather than guessed.
    private static let unpriceable: Set<String> = [
        "<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable",
    ]

    /// The rates of `model`, or nil when it's unpriced.
    func rate(for model: String) -> UsageModelRate? {
        let key = Self.stripVariant(Self.normalize(model))
        let bareName = Self.bareName(key)
        guard !bareName.isEmpty, !Self.unpriceable.contains(bareName) else { return nil }
        return rates[key]
    }

    private static func normalize(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func bareName(_ key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }

    /// Drops a bracketed variant such as the `[1m]` of `claude-fable-5-1[1m]`, which Claude
    /// Code writes for the 1M context tier. The table only knows the base name.
    private static func stripVariant(_ key: String) -> String {
        guard let bracket = key.firstIndex(of: "[") else { return key }
        return String(key[..<bracket])
    }
}
