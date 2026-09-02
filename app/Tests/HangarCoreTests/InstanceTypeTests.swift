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

extension InstanceTypeTests {

    func testSizeWeightOrdersTheUsualSizes() {
        let ordered = ["t3.nano", "t3.micro", "t3.small", "t3.medium", "m6i.large",
                       "m6i.xlarge", "m6i.2xlarge", "m6i.4xlarge", "m6i.12xlarge"]
            .map { InstanceType($0).sizeWeight }
        XCTAssertEqual(ordered, ordered.sorted(), "each size outweighs the one before")
        XCTAssertEqual(InstanceType("m6i.large").sizeWeight, 4)
        XCTAssertEqual(InstanceType("m6i.2xlarge").sizeWeight, 16)
        XCTAssertEqual(InstanceType("m6i.4xlarge").sizeWeight,
                       InstanceType("m6i.2xlarge").sizeWeight * 2)
    }

    func testMetalIsTheBiggestAndUnknownSitsInTheMiddle() {
        // Metal is the whole host: bigger than the sizes people run day to day,
        // in the region of a 24xlarge rather than beyond every size that exists.
        XCTAssertGreaterThan(InstanceType("m6i.metal").sizeWeight,
                             InstanceType("m6i.16xlarge").sizeWeight)
        XCTAssertLessThanOrEqual(InstanceType("m6i.metal").sizeWeight,
                                 InstanceType("m6i.48xlarge").sizeWeight)
        // An unfamiliar size neither dominates the picture nor disappears.
        let unknown = InstanceType("m6i.jumbo").sizeWeight
        XCTAssertGreaterThan(unknown, InstanceType("t3.small").sizeWeight)
        XCTAssertLessThan(unknown, InstanceType("m6i.large").sizeWeight)
    }
}

extension InstanceTypeTests {

    func testShortSizeFitsInsideACircle() {
        XCTAssertEqual(InstanceType("m6i.large").shortSize, "lg")
        XCTAssertEqual(InstanceType("m6i.xlarge").shortSize, "xl")
        XCTAssertEqual(InstanceType("m6i.2xlarge").shortSize, "2xl")
        XCTAssertEqual(InstanceType("m6i.8xlarge").shortSize, "8xl")
        XCTAssertEqual(InstanceType("t3.medium").shortSize, "md")
        XCTAssertEqual(InstanceType("m6i.metal").shortSize, "metal")
        XCTAssertEqual(InstanceType("weird").shortSize, "")
    }
}
