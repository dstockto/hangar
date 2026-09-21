import XCTest
@testable import HangarCore

final class PanelSelectionTests: XCTestCase {

    private let results = ["i-db", "i-repl", "i-ci", "i-etl"]

    func testTopResultIsSelected() {
        let choice = PanelSelection.next(ids: results, previous: nil, chosen: false)
        XCTAssertEqual(choice, PanelSelection(index: 0, carried: false))
    }

    func testAutoSelectionDoesNotSurviveTheNextKeystroke() {
        // "payments prod" picked i-ci for the user; typing "db" must not keep it.
        let choice = PanelSelection.next(ids: results, previous: "i-ci", chosen: false)
        XCTAssertEqual(choice?.index, 0, "the panel's own pick is not a choice")
        XCTAssertEqual(choice?.carried, false)
    }

    func testTheUsersOwnSelectionSurvivesNarrowing() {
        let choice = PanelSelection.next(ids: results, previous: "i-ci", chosen: true)
        XCTAssertEqual(choice, PanelSelection(index: 2, carried: true))
    }

    func testCarryIsDroppedWhenTheChosenHostFallsOutOfTheResults() {
        let choice = PanelSelection.next(ids: results, previous: "i-gone", chosen: true)
        XCTAssertEqual(choice?.index, 0)
        XCTAssertEqual(choice?.carried, false,
                       "back on the top result, which the next keystroke replaces")
    }

    func testNoResultsSelectsNothing() {
        XCTAssertNil(PanelSelection.next(ids: [], previous: "i-ci", chosen: true))
        XCTAssertNil(PanelSelection.next(ids: [], previous: nil, chosen: false))
    }
}
