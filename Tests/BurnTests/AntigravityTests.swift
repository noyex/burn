import Foundation
import SQLite3
import Testing
@testable import Burn

struct AntigravityTests {
    @Test func rateModelStripsEffortAndAliases() {
        #expect(AntigravityUsage.rateModel(for: "gemini-4-neon-high") == "gemini-4-neon")
        #expect(AntigravityUsage.rateModel(for: "gemini-4-hydrogen-tiered-high") == "gemini-4-hydrogen")
        #expect(AntigravityUsage.rateModel(for: "gemini-pro-orchestrator-neon") == "gemini-4-neon")
        #expect(AntigravityUsage.rateModel(for: "gemini-pro-orchestrator-g1-pro") == "gemini-4-argon")
        #expect(AntigravityUsage.rateModel(for: "gemini-3-flash-agent") == "gemini-3.5-flash")
        #expect(AntigravityUsage.rateModel(for: "gemini-3-flash-high") == "gemini-3-flash-preview")
        #expect(AntigravityUsage.rateModel(for: "gemini-3.7-flash-safety-le") == "gemini-3.7-flash")
    }

    @Test func modelNameNormalization() {
        #expect(AntigravityUsage.normalizeModelName("Gemini 4 Neon (High)") == "gemini-4-neon-high")
        #expect(AntigravityUsage.normalizeModelName("Claude 4.6 Opus") == "claude-opus-4-6")
        #expect(AntigravityUsage.isConcreteModel("gemini-4-neon"))
        #expect(AntigravityUsage.isConcreteModel("claude-opus-5-5"))
        #expect(!AntigravityUsage.isConcreteModel("gemini-3-flash-agent"))
        #expect(!AntigravityUsage.isConcreteModel("model_placeholder"))
    }

    @Test func firstPartyRatesWinForBareModelNames() {
        let doc: [String: Any] = [
            "gemini/gemini-4-hydrogen": [
                "input_cost_per_token": 1.5e-6,
                "output_cost_per_token": 7.5e-6,
                "cache_read_input_token_cost": 7.5e-8,
            ],
            "openrouter/google/gemini-4-hydrogen": [
                "input_cost_per_token": 1.5e-6,
                "output_cost_per_token": 7.5e-6,
                "cache_read_input_token_cost": 7.5e-8,
                "cache_creation_input_token_cost": 8.33e-8,
            ],
            "vendor/ambig": ["input_cost_per_token": 1e-6, "output_cost_per_token": 1e-6],
            "other/ambig": ["input_cost_per_token": 2e-6, "output_cost_per_token": 2e-6],
        ]
        let table = ModelRates.parseTable(doc)
        let rates = ModelRates(table: table, overrides: [:], aliases: [:], hash: "test")
        #expect(rates.resolve("gemini-4-hydrogen")?.standard.input == 1.5e-6)
        #expect(rates.resolve("ambig") == nil)
    }

    @Test func parsesQuotaSummaryAndHidesUnusedSyntheticReset() {
        let reqAt = parseISODate("2026-11-22T11:23:29Z")!
        let json: [String: Any] = [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        [
                            "bucketId": "gemini-weekly",
                            "window": "weekly",
                            "resetTime": "2026-11-29T11:17:09Z",
                            "description": "used some",
                            "remainingFraction": 0.97,
                        ],
                        [
                            "bucketId": "gemini-5h",
                            "window": "5h",
                            "resetTime": "2026-11-22T16:17:09Z",
                            "description": "used some",
                            "remainingFraction": 0.91,
                        ],
                    ],
                ],
                [
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        [
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "resetTime": "2026-11-22T16:23:29Z",
                            "remainingFraction": 1,
                        ],
                    ],
                ],
                [
                    "displayName": "Gemini 4 Argon",
                    "buckets": [
                        [
                            "bucketId": "gemini-argon-wtu-weekly",
                            "window": "weekly",
                            "resetTime": "2026-11-29T11:23:29Z",
                            "remainingFraction": 1,
                        ],
                    ],
                ],
            ],
        ]
        let windows = AntigravityLimitsFetcher.parseSummary(json, requestedAt: reqAt)
        #expect(windows.map(\.id) == ["5h", "week", "3p-5h", "gemini-argon-wtu-weekly"])
        #expect(windows.map(\.label) == ["5h", "Week", "3P 5h", "Argon"])
        #expect(windows.map(\.minor) == [false, false, true, true])
        #expect(abs(windows[0].percent - 9.0) < 1e-6)
        #expect(windows[0].resetsAt != nil)
        #expect(windows[2].resetsAt == nil)
    }

    @Test func decodesGoKeyringPrefixes() {
        #expect(AntigravityLimitsFetcher.decodeGoKeyringSecret("go-keyring-base64:aGVsbG8=") == "hello")
        #expect(AntigravityLimitsFetcher.decodeGoKeyringSecret("go-keyring-encoded:68656c6c6f") == "hello")
        #expect(AntigravityLimitsFetcher.decodeGoKeyringSecret("plain") == "plain")
    }

    @Test func expiredCliTokenKeepsRefreshToken() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func token(expiry: String) -> String {
            #"{"token":{"access_token":"a","refresh_token":"r","expiry":"\#(expiry)"},"auth_method":"consumer"}"#
        }
        // `now` is 2027-01-15T08:00:00Z.
        #expect(AntigravityLimitsFetcher.parseCliToken(token(expiry: "2027-01-15T09:00:00Z"), now: now)
            == .valid(accessToken: "a", authMethod: .personal))
        #expect(AntigravityLimitsFetcher.parseCliToken(token(expiry: "2027-01-15T07:00:00Z"), now: now)
            == .expired(refreshToken: "r", authMethod: .personal))
        #expect(AntigravityLimitsFetcher.parseCliToken(#"{"token":{"access_token":"a"}}"#, now: now)
            == .expired(refreshToken: nil, authMethod: nil))
    }
}
