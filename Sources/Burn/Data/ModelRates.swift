import Foundation

/// Per-token prices of one model (LiteLLM format). `*P` are OpenAI priority (fast mode) variants.
struct ModelRate: Sendable {
    let input, output, cacheRead, cacheWrite: Double
    let inputP, outputP, cacheReadP, cacheWriteP: Double
}

/// Pricing table. Costs mirror T3 Code's: flat base rates, priority rates for Codex fast mode.
struct ModelRates: Sendable {
    let table: [String: ModelRate]

    static let empty = ModelRates(table: [:])
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    func rate(for model: String?) -> ModelRate? {
        guard let model else { return nil }
        return table[model] ?? table["anthropic/" + model] ?? table["openai/" + model]
    }

    func cost(provider: String, model: String?, input: Int64, cacheRead: Int64, cacheWrite: Int64,
              output: Int64, fast: Bool) -> Double {
        guard let r = rate(for: model) else { return 0 }
        if fast && provider == "codex" {
            return Double(input) * r.inputP + Double(cacheRead) * r.cacheReadP
                + Double(cacheWrite) * r.cacheWriteP + Double(output) * r.outputP
        }
        return Double(input) * r.input + Double(cacheRead) * r.cacheRead
            + Double(cacheWrite) * r.cacheWrite + Double(output) * r.output
    }

    /// T3 copy, then fresh Burn cache, then network, then stale cache, then nothing.
    static func load() async -> ModelRates {
        let fm = FileManager.default
        let t3 = NSHomeDirectory() + "/.t3/userdata/usage-model-rates.json"
        if let data = fm.contents(atPath: t3),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let doc = root["document"] as? [String: Any] {
            let r = parse(doc)
            if !r.table.isEmpty { return r }
        }
        let cache = UsageStore.supportDir + "/model-rates.json"
        let age = (try? fm.attributesOfItem(atPath: cache)[.modificationDate] as? Date).flatMap { $0 }
            .map { Date().timeIntervalSince($0) }
        if let age, age < 24 * 3600, let r = readCache(cache) { return r }
        if let (status, data) = try? await httpData(URLRequest(url: sourceURL)), status == 200,
           let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let r = parse(doc)
            if r.table.count > 100 {
                try? fm.createDirectory(atPath: UsageStore.supportDir, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: cache), options: .atomic)
                return r
            }
        }
        return readCache(cache) ?? .empty
    }

    private static func readCache(_ path: String) -> ModelRates? {
        guard let data = FileManager.default.contents(atPath: path),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let r = parse(doc)
        return r.table.isEmpty ? nil : r
    }

    static func parse(_ doc: [String: Any]) -> ModelRates {
        var table: [String: ModelRate] = [:]
        table.reserveCapacity(doc.count)
        for (model, v) in doc {
            guard let d = v as? [String: Any] else { continue }
            func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
            let (i, o, cr, cw) = (num("input_cost_per_token"), num("output_cost_per_token"),
                                  num("cache_read_input_token_cost"), num("cache_creation_input_token_cost"))
            if i == nil && o == nil && cr == nil && cw == nil { continue }
            table[model] = ModelRate(
                input: i ?? 0, output: o ?? 0, cacheRead: cr ?? 0, cacheWrite: cw ?? 0,
                inputP: num("input_cost_per_token_priority") ?? i ?? 0,
                outputP: num("output_cost_per_token_priority") ?? o ?? 0,
                cacheReadP: num("cache_read_input_token_cost_priority") ?? cr ?? 0,
                cacheWriteP: num("cache_creation_input_token_cost_priority") ?? cw ?? 0)
        }
        return ModelRates(table: table)
    }
}
