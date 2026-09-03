import XCTest
@testable import HangarCore

/// The rule this exists to keep: a product is never drawn in a colour that
/// means something about state.
final class CategoryHueTests: XCTestCase {
    /// Enough names to hit every slot several times over.
    private let names = ["payments", "billing", "identity", "search", "edge",
                         "ledger", "notify", "platform", "core", "web", "api",
                         "data", "risk", "auth", "mail", "prod", "stage", "qa",
                         "dev", "perf", "sandbox", "uat", "", "a", "zzzz"]

    func testEveryHueClearsTheStateColours() {
        for name in names {
            let hue = CategoryHue.degrees(for: name)
            XCTAssertFalse(CategoryHue.isReserved(hue),
                           "\(name) landed on \(hue), which state owns")
        }
    }

    func testEveryHueSitsInsideTheArc() {
        for name in names {
            let hue = CategoryHue.degrees(for: name)
            XCTAssertTrue(CategoryHue.arc.contains(hue), "\(name) landed on \(hue)")
        }
    }

    /// Every slot has to clear the reserved bands, not just the ones these names
    /// happen to hit.
    func testNoSlotAnywhereInTheArcIsReserved() {
        for slot in 0..<CategoryHue.slots {
            let width = CategoryHue.arc.upperBound - CategoryHue.arc.lowerBound
            let hue = CategoryHue.arc.lowerBound
                + Double(slot) * width / Double(CategoryHue.slots)
            XCTAssertFalse(CategoryHue.isReserved(hue), "slot \(slot) is at \(hue)")
        }
    }

    func testTheSameNameAlwaysGetsTheSameHue() {
        XCTAssertEqual(CategoryHue.degrees(for: "payments"),
                       CategoryHue.degrees(for: "payments"))
        XCTAssertNotEqual(CategoryHue.degrees(for: "payments"),
                          CategoryHue.degrees(for: "billing"),
                          "two products this common sharing a colour would be unlucky")
    }

    func testTheArcIsUsedRatherThanOneCornerOfIt() {
        let used = Set(names.map { CategoryHue.degrees(for: $0) })
        XCTAssertGreaterThanOrEqual(used.count, 8,
                                    "25 names should spread across most of the ten slots")
    }
}
