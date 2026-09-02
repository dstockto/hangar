import XCTest
@testable import HangarCore

/// An instance type string says what it is without asking AWS.
final class InstanceTypeTests: XCTestCase {

    func testFamilySeriesGenerationAndSize() {
        let type = InstanceType("m6i.2xlarge")
        XCTAssertEqual(type.family, "m6i")
        XCTAssertEqual(type.series, "m")
        XCTAssertEqual(type.generation, 6)
        XCTAssertEqual(type.size, "2xlarge")
    }

    func testBurstableIsTheTSeries() {
        XCTAssertTrue(InstanceType("t3.micro").isBurstable)
        XCTAssertFalse(InstanceType("m6i.large").isBurstable)
    }

    func testPreviousGenerationMeansWhatAWSMeansByIt() {
        XCTAssertTrue(InstanceType("m4.large").isPreviousGeneration)
        XCTAssertTrue(InstanceType("t2.micro").isPreviousGeneration)
        // One generation behind the newest is not a finding: AWS still sells
        // m6i, and flagging it would bury the m4 that actually matters.
        XCTAssertFalse(InstanceType("m6i.large").isPreviousGeneration)
        XCTAssertFalse(InstanceType("m7g.large").isPreviousGeneration)
        // A family Hangar has no entry for is never called out: a wrong finding
        // is worse than a missing one.
        XCTAssertFalse(InstanceType("q9.large").isPreviousGeneration)
    }

    func testAMalformedTypeDoesNotCrashOrLie() {
        let type = InstanceType("weird")
        XCTAssertEqual(type.family, "weird")
        XCTAssertEqual(type.size, "")
        XCTAssertNil(type.generation)
        XCTAssertFalse(type.isPreviousGeneration)
        XCTAssertEqual(InstanceType("").family, "")
    }
}
