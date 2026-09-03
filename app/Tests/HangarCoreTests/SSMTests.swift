import XCTest
@testable import HangarCore

final class SSMTests: XCTestCase {

    private func parse(_ json: String) throws -> SSM.Page {
        try SSM.parse(Data(json.utf8))
    }

    func testMapsAnInstanceInformationEntry() throws {
        let page = try parse("""
        {"InstanceInformationList":[{
          "InstanceId":"i-0aaaaaaaaaaaaaaaa",
          "PingStatus":"Online",
          "IPAddress":"10.0.0.1",
          "ComputerName":"web1.prod.example.com",
          "PlatformName":"Amazon Linux",
          "PlatformVersion":"2023",
          "ResourceType":"EC2Instance"
        }]}
        """)
        XCTAssertEqual(page.instances.count, 1)
        let host = page.instances[0]
        XCTAssertEqual(host.id, "i-0aaaaaaaaaaaaaaaa")
        XCTAssertEqual(host.state, "running")
        XCTAssertEqual(host.privateIP, "10.0.0.1")
        XCTAssertEqual(host.host, "web1.prod.example.com")
        XCTAssertEqual(host.platform, "Amazon Linux 2023")
        XCTAssertEqual(host.origin, .ssm)
    }

    /// PingStatus is what SSM knows about the agent, not the machine. Calling a
    /// ConnectionLost host "stopped" would be a state SSM never said.
    func testAnythingButOnlineIsUnknownRatherThanStopped() throws {
        let page = try parse("""
        {"InstanceInformationList":[
          {"InstanceId":"i-1","PingStatus":"ConnectionLost"},
          {"InstanceId":"i-2","PingStatus":"Inactive"}
        ]}
        """)
        XCTAssertEqual(page.instances.map(\.state), ["unknown", "unknown"])
    }

    func testAShortComputerNameFallsBackToTheAddress() throws {
        let page = try parse("""
        {"InstanceInformationList":[{
          "InstanceId":"i-1","PingStatus":"Online",
          "IPAddress":"10.0.0.7","ComputerName":"WIN-3AB2"
        }]}
        """)
        XCTAssertEqual(page.instances[0].host, "10.0.0.7")
        XCTAssertEqual(page.instances[0].role, "WIN-3AB2", "the name is still worth showing")
    }

    /// On-prem managed instances are exactly the hosts EC2 could never show.
    func testManagedInstancesAreKept() throws {
        let page = try parse("""
        {"InstanceInformationList":[{
          "InstanceId":"mi-0123456789abcdef0","PingStatus":"Online",
          "IPAddress":"192.168.1.4","ComputerName":"rack12.dc.internal",
          "ResourceType":"ManagedInstance"
        }]}
        """)
        XCTAssertEqual(page.instances.count, 1)
        XCTAssertEqual(page.instances[0].tags["ssm_resource_type"], "ManagedInstance")
    }

    func testPaginationTokenIsCarried() throws {
        let page = try parse("{\"InstanceInformationList\":[],\"NextToken\":\"abc\"}")
        XCTAssertEqual(page.nextToken, "abc")
    }

    func testEntriesWithNoInstanceIdAreSkipped() throws {
        let page = try parse("{\"InstanceInformationList\":[{\"PingStatus\":\"Online\"}]}")
        XCTAssertTrue(page.instances.isEmpty)
    }

    func testUnusableJSONThrowsRatherThanReturningNothing() {
        XCTAssertThrowsError(try SSM.parse(Data("not json".utf8)))
    }

    // MARK: - Falling back

    /// Only a refusal is worth falling back from. A network error means the next
    /// call fails the same way.
    func testOnlyAuthorizationFailuresTriggerTheFallback() {
        XCTAssertTrue(SSM.isAuthorizationFailure(
            HangarError.http(403, "User is not authorized to perform: ec2:DescribeInstances")))
        XCTAssertTrue(SSM.isAuthorizationFailure(
            HangarError.http(400, "UnauthorizedOperation")))
        XCTAssertFalse(SSM.isAuthorizationFailure(HangarError.http(500, "Internal error")))
        XCTAssertFalse(SSM.isAuthorizationFailure(HangarError.timedOut("slow")))
    }

    // MARK: - Signing

    /// x-amz-target has to be in the canonical headers or AWS answers 403 with a
    /// signature mismatch and no clue which header caused it.
    func testTheTargetHeaderIsSignedAndSent() {
        let signer = SigV4(
            credentials: AWSCredentials(accessKeyId: "AKIDEXAMPLE",
                                        secretAccessKey: "secret",
                                        sessionToken: nil, expiration: nil),
            region: "us-west-2", service: "ssm")
        let request = signer.sign(url: URL(string: "https://ssm.us-west-2.amazonaws.com/")!,
                                  body: "{}", contentType: SigV4.jsonContentType,
                                  extraHeaders: ["x-amz-target": SSM.target])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-target"), SSM.target)
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authorization.contains("x-amz-target"),
                      "signed headers must name it, not only the wire")
        XCTAssertTrue(authorization.contains("content-type;host;x-amz-date;x-amz-target"))
    }

    func testTheFormProtocolIsUnchanged() {
        let signer = SigV4(
            credentials: AWSCredentials(accessKeyId: "AKIDEXAMPLE",
                                        secretAccessKey: "secret",
                                        sessionToken: nil, expiration: nil),
            region: "us-west-2", service: "ec2")
        let request = signer.sign(url: URL(string: "https://ec2.us-west-2.amazonaws.com/")!,
                                  body: "Action=DescribeInstances")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       SigV4.formContentType)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-amz-target"))
    }
}
