import Foundation

/// `ssm:DescribeInstanceInformation`, the fallback for an account that grants
/// Session Manager but not EC2 read.
///
/// It is tried on its own when `DescribeInstances` comes back denied, so an
/// under-permissioned SRE gets a fleet without ever learning the name of the API
/// that refused them. JSON rather than the query protocol, which is why SigV4
/// grew a content type and a signed `x-amz-target`.
///
/// Discovery only. Using SSM as *transport* would need the aws CLI and its
/// session-manager plugin at runtime, and not depending on either is a product
/// property rather than an accident.
public final class SSM {
    private let credentials: AWSCredentials
    private let region: String

    public init(credentials: AWSCredentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    public static let target = "AmazonSSM.DescribeInstanceInformation"

    public func describeInstanceInformation() async throws -> [Instance] {
        var all: [Instance] = []
        var nextToken: String?
        repeat {
            var payload: [String: Any] = ["MaxResults": 50]
            if let nextToken { payload["NextToken"] = nextToken }
            let body = String(
                data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

            let url = try AWSRegion.endpoint(service: "ssm", region: region)
            let signer = SigV4(credentials: credentials, region: region, service: "ssm")
            let request = signer.sign(url: url, body: body,
                                      contentType: SigV4.jsonContentType,
                                      extraHeaders: ["x-amz-target": SSM.target])

            let (data, response) = try await HangarHTTP.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw HangarError.http(code, SSM.errorMessage(from: data) ?? text)
            }
            let page = try SSM.parse(data)
            all.append(contentsOf: page.instances)
            nextToken = page.nextToken
        } while nextToken != nil && !nextToken!.isEmpty
        return all
    }

    // MARK: - Parsing

    public struct Page: Sendable {
        public var instances: [Instance]
        public var nextToken: String?
    }

    public static func parse(_ data: Data) throws -> Page {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HangarError.malformedResponse("SSM returned unusable JSON")
        }
        let list = root["InstanceInformationList"] as? [[String: Any]] ?? []
        var instances: [Instance] = []
        for entry in list {
            guard let id = entry["InstanceId"] as? String, !id.isEmpty else { continue }
            let computerName = entry["ComputerName"] as? String ?? ""
            let address = entry["IPAddress"] as? String
            // ComputerName is a hostname often enough to be worth using, and a
            // NetBIOS-style short name often enough that it has to be checked.
            let target = computerName.contains(".") ? computerName : (address ?? computerName)

            var tags: [String: String] = [:]
            if !computerName.isEmpty { tags["Name"] = computerName }
            if let target = target.isEmpty ? nil : target { tags["hostname"] = target }
            if let value = entry["ResourceType"] as? String { tags["ssm_resource_type"] = value }
            if let value = entry["AgentVersion"] as? String { tags["ssm_agent_version"] = value }

            let platform = [entry["PlatformName"] as? String,
                            entry["PlatformVersion"] as? String]
                .compactMap { $0 }.joined(separator: " ")

            instances.append(Instance(
                id: id,
                // PingStatus is what SSM knows about the agent, not the machine.
                // Online means reachable; anything else is honestly unknown
                // rather than stopped, which would be a state SSM never said.
                state: (entry["PingStatus"] as? String) == "Online" ? "running" : "unknown",
                type: "", privateIP: address, publicIP: nil,
                availabilityZone: nil,
                launchTime: entry["RegistrationDate"] as? String ?? "",
                tags: tags,
                platform: platform.isEmpty ? nil : platform,
                source: .ssm,
                preferredAlias: nil))
        }
        return Page(instances: instances, nextToken: root["NextToken"] as? String)
    }

    static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (root["message"] as? String) ?? (root["Message"] as? String)
    }

    /// Whether a failure is AWS saying no rather than something being broken.
    /// Only a refusal is worth falling back from; a network error means trying
    /// the next call will fail the same way.
    public static func isAuthorizationFailure(_ error: Error) -> Bool {
        if let error = error as? HangarError, case .http(let code, let message) = error {
            if code == 403 { return true }
            let lowered = message.lowercased()
            return lowered.contains("unauthorized") || lowered.contains("not authorized")
                || lowered.contains("accessdenied") || lowered.contains("access denied")
                || lowered.contains("unauthorizedoperation")
        }
        return false
    }
}
