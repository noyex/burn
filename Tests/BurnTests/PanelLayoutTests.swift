import Testing
@testable import Burn

struct PanelLayoutTests {
    private let all: [ProviderID] = [.claude, .codex, .cursor]
    private let custom: (ProviderID) -> CardSize = { $0 == .claude ? .l : .m }

    @Test func autoSizesByCount() {
        #expect(PanelLayout.auto.sizes(for: [.codex], custom: custom) == [.codex: .l])
        #expect(PanelLayout.auto.sizes(for: [.codex, .cursor], custom: custom) == [.codex: .m, .cursor: .m])
        #expect(PanelLayout.auto.sizes(for: all, custom: custom) == [.claude: .l, .codex: .s, .cursor: .s])
    }

    @Test func fixedLayouts() {
        #expect(PanelLayout.grid.sizes(for: all, custom: custom).values.allSatisfy { $0 == .m })
        #expect(PanelLayout.list.sizes(for: all, custom: custom).values.allSatisfy { $0 == .s })
        #expect(PanelLayout.custom.sizes(for: all, custom: custom) == [.claude: .l, .codex: .m, .cursor: .m])
    }

    @Test func mediumCardsPairUp() {
        let rows = PanelArrangement.rows(all, sizes: [.claude: .l, .codex: .m, .cursor: .m])
        #expect(rows == [[.claude], [.codex, .cursor]])
        let split = PanelArrangement.rows(all, sizes: [.claude: .m, .codex: .s, .cursor: .m])
        #expect(split == [[.claude], [.codex], [.cursor]])
    }

    @Test func closestToLimitSortsByRemaining() {
        let remaining: [ProviderID: Double] = [.claude: 40, .codex: 80, .cursor: 40]
        #expect(PanelArrangement.closestToLimit(all) { remaining[$0] } == [.claude, .cursor, .codex])
        #expect(PanelArrangement.closestToLimit(all) { $0 == .cursor ? 10 : nil } == [.cursor, .claude, .codex])
    }

    @Test func mergeKeepsHiddenInPlace() {
        #expect(PanelArrangement.merge([.cursor, .claude], into: all) == [.cursor, .codex, .claude])
        #expect(PanelArrangement.merge([.codex, .claude, .cursor], into: all) == [.codex, .claude, .cursor])
    }

    @Test func savedOrderIsRepaired() {
        #expect(PanelArrangement.order(from: ["cursor", "nope", "cursor"]) == [.cursor, .claude, .codex])
    }
}
