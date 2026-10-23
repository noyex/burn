import CryptoKit
import Foundation

/// Per-token prices of one speed tier.
struct TokenRates: Sendable, Equatable {
    let input, output, cacheRead, cacheCreation: Double

    func scaled(by m: Double) -> TokenRates {
        TokenRates(input: input * m, output: output * m, cacheRead: cacheRead * m, cacheCreation: cacheCreation * m)
    }
}

/// Standard rates plus the optional fast / ultrafast tiers of one model.
struct ModelRate: Sendable, Equatable {
    let standard: TokenRates
    let fast: TokenRates?
    let ultrafast: TokenRates?

    func rates(at speed: Speed) -> TokenRates {
        switch speed {
        case .standard: standard
        case .fast: fast ?? standard
        case .ultrafast: ultrafast ?? standard
        }
    }
}

/// Pricing table. Mirrors T3 Code's `usagePricing.ts` (`parseRateTable`, `resolveRate`, `priceUsage`).
struct ModelRates: Sendable {
    let table: [String: ModelRate]
    /// Per-model price overrides from T3's settings (`usagePriceOverrides`), keyed by trimmed model name.
    let overrides: [String: TokenRates]
    /// Model aliases from T3's settings (`usageModelAliases`), chains already resolved.
    let aliases: [String: String]
    /// Identifies the table, overrides and aliases; a change means stored costs are stale.
    let hash: String

    static let empty = ModelRates(table: [:], overrides: [:], aliases: [:], hash: "empty")
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    /// T3's own rates file is trusted for this long, then Burn looks for fresher rates.
    private static let t3MaxAge: TimeInterval = 3 * 24 * 3600

    // MARK: Pricing

    /// `priceUsage(...).costUsd`: a provider-reported cost wins; otherwise list price at the record's speed.
    func cost(model: String, rateModel: String?, speed: Speed, uncached: Int64, cached: Int64,
              cacheCreation: Int64, output: Int64, reported: Double?) -> Double {
        var model = model
        var rateModel = rateModel
        if let target = aliases[model] { model = target; rateModel = nil }
        let override = overrides[model.trimmingCharacters(in: .whitespacesAndNewlines)]
        let reported = override == nil ? reported.flatMap { $0.isFinite ? $0 : nil } : nil
        let base: ModelRate?
        if let override { base = ModelRate(standard: override, fast: nil, ultrafast: nil) }
        else { base = resolve(rateModel ?? model) }
        guard let base else { return reported ?? 0 }
        let r = base.rates(at: speed)
        // Same summation order as T3: input + cacheRead + cacheWrite + output.
        let list = Double(uncached) * r.input + Double(cached) * r.cacheRead
            + Double(cacheCreation) * r.cacheCreation + Double(output) * r.output
        if let reported, list <= 0 { return reported }
        return reported ?? list
    }

    private static let unpriceable: Set<String> = ["<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable"]

    /// `resolveRate`: lowercase, drop a `[1m]`-style suffix, refuse bare family names.
    func resolve(_ model: String) -> ModelRate? {
        let key = Self.stripVariantSuffix(Self.normalizeKey(model))
        let bare = Self.bareName(key)
        if bare.isEmpty || Self.unpriceable.contains(bare) { return nil }
        return table[key]
    }

    static func normalizeKey(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func bareName(_ key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }

    static func stripVariantSuffix(_ key: String) -> String {
        guard let b = key.firstIndex(of: "[") else { return key }
        return String(key[..<b])
    }

    // MARK: Parsing

    private static func finite(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// `readTokenRates`: both input and output are required; missing cache rates scale from the standard tier,
    /// or fall back to the plain input rate.
    private static func readTokenRates(_ e: [String: Any], _ suffix: String, standard: TokenRates? = nil) -> TokenRates? {
        guard let input = finite(e["input_cost_per_token" + suffix]),
              let output = finite(e["output_cost_per_token" + suffix]) else { return nil }
        func cache(_ name: String, _ std: KeyPath<TokenRates, Double>) -> Double {
            if let v = finite(e[name + suffix]) { return v }
            if let standard, standard.input > 0 { return standard[keyPath: std] / standard.input * input }
            return input
        }
        return TokenRates(input: input, output: output,
                          cacheRead: cache("cache_read_input_token_cost", \.cacheRead),
                          cacheCreation: cache("cache_creation_input_token_cost", \.cacheCreation))
    }

    /// `parseRateTable` (LiteLLM document -> normalized-name table, plus unambiguous bare-name aliases).
    static func parseTable(_ document: [String: Any]) -> [String: ModelRate] {
        var table: [String: ModelRate] = [:]
        table.reserveCapacity(document.count)
        // Sorted so that colliding normalized names resolve the same way on every run.
        for name in document.keys.sorted() {
            guard let e = document[name] as? [String: Any],
                  let standard = readTokenRates(e, "") else { continue }
            let key = normalizeKey(name)
            if key.isEmpty { continue }
            var multiple: Double?
            if let specific = e["provider_specific_entry"] as? [String: Any], let f = finite(specific["fast"]), f > 0 { multiple = f }
            table[key] = ModelRate(
                standard: standard,
                fast: multiple.map { standard.scaled(by: $0) } ?? readTokenRates(e, "_priority", standard: standard),
                ultrafast: readTokenRates(e, "_ultrafast", standard: standard))
        }
        var candidates: [String: ModelRate?] = [:]
        for (key, rate) in table {
            let alias = bareName(key)
            if alias.isEmpty || alias == key || table[alias] != nil { continue }
            if let held = candidates[alias] {
                if let h = held, h != rate { candidates[alias] = .some(nil) }
            } else {
                candidates[alias] = .some(rate)
            }
        }
        for (alias, rate) in candidates { if let rate { table[alias] = rate } }
        return table
    }

    /// T3 settings: `usagePriceOverrides` (per million tokens) and `usageModelAliases`.
    private static func readSettings() -> (overrides: [String: TokenRates], aliases: [String: String], raw: Data) {
        let path = NSHomeDirectory() + "/.t3/userdata/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([:], [:], Data()) }
        var overrides: [String: TokenRates] = [:]
        for (model, v) in root["usagePriceOverrides"] as? [String: Any] ?? [:] {
            guard let p = v as? [String: Any], let i = finite(p["inputCostPerMillionTokens"]),
                  let o = finite(p["outputCostPerMillionTokens"]) else { continue }
            overrides[model.trimmingCharacters(in: .whitespacesAndNewlines)] = TokenRates(
                input: i / 1e6, output: o / 1e6,
                cacheRead: (finite(p["cacheReadCostPerMillionTokens"]) ?? i) / 1e6,
                cacheCreation: (finite(p["cacheWriteCostPerMillionTokens"]) ?? i) / 1e6)
        }
        // `resolveModelAliases`: follow chains, drop cycles.
        let raw = (root["usageModelAliases"] as? [String: String]) ?? [:]
        var aliases: [String: String] = [:]
        for model in raw.keys {
            var seen: Set<String> = [model]
            var target = raw[model]!
            while raw[target] != nil, !seen.contains(target) { seen.insert(target); target = raw[target]! }
            if raw[target] == nil { aliases[model] = target }
        }
        let canon = (try? JSONSerialization.data(withJSONObject: ["o": root["usagePriceOverrides"] ?? [:], "a": raw],
                                                 options: [.sortedKeys])) ?? Data()
        return (overrides, aliases, canon)
    }

    static func make(document: [String: Any]) -> ModelRates {
        let table = parseTable(document)
        let settings = readSettings()
        var hasher = SHA256()
        if let canon = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) { hasher.update(data: canon) }
        hasher.update(data: settings.raw)
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ModelRates(table: table, overrides: settings.overrides, aliases: settings.aliases, hash: hash)
    }

    // MARK: Loading

    /// T3's rates copy, then fresh Burn cache, then network, then whatever stale copy exists, then nothing.
    static func load() async -> ModelRates {
        let fm = FileManager.default
        let t3Path = NSHomeDirectory() + "/.t3/userdata/usage-model-rates.json"
        var t3: (rates: ModelRates, age: TimeInterval)?
        if let data = fm.contents(atPath: t3Path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let doc = root["document"] as? [String: Any] {
            let r = make(document: doc)
            if !r.table.isEmpty {
                let fetched = (root["fetchedAtMs"] as? NSNumber)?.doubleValue ?? 0
                t3 = (r, Date().timeIntervalSince1970 - fetched / 1000)
            }
        }
        if let t3, t3.age < t3MaxAge { return t3.rates }

        let cache = UsageStore.supportDir + "/model-rates.json"
        let age = (try? fm.attributesOfItem(atPath: cache)[.modificationDate] as? Date).flatMap { $0 }
            .map { Date().timeIntervalSince($0) }
        if let age, age < 24 * 3600, let r = readCache(cache) { return r }
        if let (status, data) = try? await httpData(URLRequest(url: sourceURL)), status == 200,
           let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let r = make(document: doc)
            if r.table.count > 100 {
                try? fm.createDirectory(atPath: UsageStore.supportDir, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: cache), options: .atomic)
                return r
            }
        }
        return readCache(cache) ?? t3?.rates ?? .empty
    }

    /// Rates exactly as T3 has them on disk, regardless of age (verification).
    static func loadT3Only() -> ModelRates? {
        let path = NSHomeDirectory() + "/.t3/userdata/usage-model-rates.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let doc = root["document"] as? [String: Any] else { return nil }
        let r = make(document: doc)
        return r.table.isEmpty ? nil : r
    }

    private static func readCache(_ path: String) -> ModelRates? {
        guard let data = FileManager.default.contents(atPath: path),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let r = make(document: doc)
        return r.table.isEmpty ? nil : r
    }
}
