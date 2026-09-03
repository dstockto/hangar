import XCTest
@testable import HangarCore

final class HostsFileTests: XCTestCase {

    func testReadsTheDocumentedColumns() {
        let result = HostsFile.parse("""
        alias,hostname,user,port,product,env,role
        payments-prod-web-1,10.0.4.11,ec2-user,22,payments,prod,web
        """)
        XCTAssertEqual(result.hosts.count, 1)
        let host = result.hosts[0]
        XCTAssertEqual(host.aliasStem, "payments-prod-web-1")
        XCTAssertEqual(host.host, "10.0.4.11")
        XCTAssertEqual(host.product, "payments")
        XCTAssertEqual(host.env, "prod")
        XCTAssertEqual(host.role, "web")
        XCTAssertEqual(host.tags["ssh_config_user"], "ec2-user")
        XCTAssertEqual(host.origin, .hostsFile)
    }

    func testUnknownColumnsBecomeTags() {
        let result = HostsFile.parse("""
        alias,hostname,datacenter,owner
        db1,10.0.0.9,ams3,platform
        """)
        XCTAssertEqual(result.hosts[0].tags["datacenter"], "ams3")
        XCTAssertEqual(result.hosts[0].tags["owner"], "platform",
                       "a fleet's own columns are how it wants the menu grouped")
    }

    func testAliasAloneIsEnough() {
        let result = HostsFile.parse("alias\nbastion.example.com\n")
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].host, "bastion.example.com",
                       "an alias with no address is one ssh resolves itself")
    }

    func testHostnameAloneIsEnough() {
        let result = HostsFile.parse("hostname\n10.0.0.5\n")
        XCTAssertEqual(result.hosts.first?.aliasStem, "10.0.0.5")
    }

    // MARK: - Refusals

    /// A count alone sends someone hunting through a spreadsheet for a row
    /// Hangar already found.
    func testRefusalsNameTheirLine() {
        let result = HostsFile.parse("""
        alias,hostname
        good,10.0.0.1
        bad alias,10.0.0.2
        """)
        XCTAssertEqual(result.hosts.map(\.aliasStem), ["good"])
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("line 3"))
    }

    func testRefusesAnAliasThatCouldActAsAPattern() {
        let result = HostsFile.parse("alias,hostname\n*,10.0.0.1\n")
        XCTAssertTrue(result.hosts.isEmpty,
                      "a catch-all Host line outranks the user's whole ssh config")
        XCTAssertEqual(result.skipped.count, 1)
    }

    func testRefusesAHostnameWithADirectiveInIt() {
        let result = HostsFile.parse("alias,hostname\nweb1,\"10.0.0.1\nProxyCommand evil\"\n")
        XCTAssertTrue(result.hosts.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
    }

    func testRepeatedAliasesAreRefusedRatherThanRenumbered() {
        let result = HostsFile.parse("""
        alias,hostname
        web1,10.0.0.1
        web1,10.0.0.2
        """)
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertTrue(result.skipped[0].contains("repeats"))
    }

    func testAFileWithNoRecognisedColumnSaysSo() {
        let result = HostsFile.parse("colour,size\nred,large\n")
        XCTAssertTrue(result.hosts.isEmpty)
        XCTAssertTrue(result.skipped[0].contains("line 1"))
    }

    // MARK: - Spreadsheet quoting

    func testQuotedFieldsWithCommas() {
        let result = HostsFile.parse("""
        alias,hostname,note
        web1,10.0.0.1,"one, two, three"
        """)
        XCTAssertEqual(result.hosts[0].tags["note"], "one, two, three")
    }

    func testDoubledQuotesAreALiteralQuote() {
        let result = HostsFile.parse("alias,hostname,note\nweb1,10.0.0.1,\"say \"\"hi\"\"\"\n")
        XCTAssertEqual(result.hosts[0].tags["note"], "say \"hi\"")
    }

    func testBlankAndCommentedLinesAreSkipped() {
        let result = HostsFile.parse("""
        alias,hostname

        # this row is a note
        web1,10.0.0.1
        """)
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testCarriageReturnsFromAWindowsExportAreHandled() {
        let result = HostsFile.parse("alias,hostname\r\nweb1,10.0.0.1\r\n")
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].host, "10.0.0.1")
    }

    func testTheShippedExampleParses() {
        let result = HostsFile.parse(HostsFile.example)
        XCTAssertEqual(result.hosts.count, 2)
        XCTAssertTrue(result.skipped.isEmpty,
                      "the example is the format; it has to be the format")
    }

    // MARK: - Written to Hangar's file

    func testCSVHostsAreWrittenUnlikeImportedOnes() {
        let result = HostsFile.parse("alias,hostname\nweb1,10.0.0.1\n")
        let writer = SSHConfigWriter(config: .standard())
        XCTAssertEqual(writer.entries(for: result.hosts).count, 1,
                       "these are Hangar's to write; nothing else defines them")
    }
}
