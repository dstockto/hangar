import Foundation

/// ec2:DescribeInstances over the query protocol. The response is XML, so this
/// walks it with a SAX parser and keys off each element's path relative to the
/// instance node. That matters: privateIpAddress also appears deeper inside
/// networkInterfaceSet, and a naive search would pick up the wrong one.
public final class EC2 {
    public struct Filter: Sendable {
        public var name: String
        public var values: [String]
        public init(name: String, values: [String]) {
            self.name = name
            self.values = values
        }
    }

    private let credentials: AWSCredentials
    private let region: String

    public init(credentials: AWSCredentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    public func describeInstances(filters: [Filter] = []) async throws -> [Instance] {
        var all: [Instance] = []
        var nextToken: String?
        repeat {
            var params: [String: String] = [
                "Action": "DescribeInstances",
                "Version": "2016-11-15",
                "MaxResults": "1000",
            ]
            for (i, filter) in filters.enumerated() {
                params["Filter.\(i + 1).Name"] = filter.name
                for (j, value) in filter.values.enumerated() {
                    params["Filter.\(i + 1).Value.\(j + 1)"] = value
                }
            }
            if let nextToken { params["NextToken"] = nextToken }

            let body = params.keys.sorted()
                .map { "\(EC2.encode($0))=\(EC2.encode(params[$0]!))" }
                .joined(separator: "&")

            let url = try AWSRegion.endpoint(service: "ec2", region: region)
            let signer = SigV4(credentials: credentials, region: region, service: "ec2")
            let request = signer.sign(url: url, body: body)

            let (data, response) = try await HangarHTTP.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw HangarError.http(code, EC2.errorMessage(from: text) ?? text)
            }

            let parser = InstanceParser()
            let page = try parser.parse(data)
            all.append(contentsOf: page.instances)
            nextToken = page.nextToken
        } while nextToken != nil && !nextToken!.isEmpty

        return all
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func errorMessage(from xml: String) -> String? {
        guard let start = xml.range(of: "<Message>"),
              let end = xml.range(of: "</Message>") else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}

final class InstanceParser: NSObject, XMLParserDelegate {
    struct Page {
        var instances: [Instance] = []
        var nextToken: String?
    }

    private var path: [String] = []
    private var text = ""
    private var page = Page()

    private var instanceDepth: Int?
    private var current: Instance?
    private var pendingTagKey: String?
    private var pendingTagValue: String?

    private static let instancePath = ["DescribeInstancesResponse", "reservationSet",
                                      "item", "instancesSet", "item"]

    func parse(_ data: Data) throws -> Page {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw HangarError.malformedResponse(
                parser.parserError?.localizedDescription ?? "XML parse failed")
        }
        return page
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        path.append(element)
        text = ""
        if instanceDepth == nil && path == InstanceParser.instancePath {
            instanceDepth = path.count
            current = Instance(id: "", state: "", type: "", privateIP: nil,
                               publicIP: nil, availabilityZone: nil,
                               launchTime: "", tags: [:])
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast(); text = "" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if path.count == 2, element == "nextToken" {
            page.nextToken = value
            return
        }

        guard let depth = instanceDepth, path.count >= depth else { return }

        if path.count == depth, element == "item" {
            if var instance = current, !instance.id.isEmpty {
                instance.tags = instance.tags.filter { !$0.key.isEmpty }
                page.instances.append(instance)
            }
            current = nil
            instanceDepth = nil
            return
        }

        let relative = path[depth...].joined(separator: "/")
        switch relative {
        case "instanceId":                current?.id = value
        case "instanceType":              current?.type = value
        case "launchTime":                current?.launchTime = value
        case "privateIpAddress":          current?.privateIP = value
        case "ipAddress":                 current?.publicIP = value
        case "instanceState/name":        current?.state = value
        case "placement/availabilityZone":current?.availabilityZone = value
        case "imageId":                   current?.imageID = value
        case "vpcId":                     current?.vpcID = value
        case "subnetId":                  current?.subnetID = value
        case "keyName":                   current?.keyName = value
        case "architecture":              current?.architecture = value
        case "platformDetails":           current?.platform = value
        case "instanceLifecycle":         current?.lifecycle = value
        case "privateDnsName":            current?.privateDNS = value
        case "monitoring/state":          current?.monitoring = value
        case "rootDeviceType":            current?.rootDeviceType = value
        case "stateReason/message":       current?.stateReason = value
        case "iamInstanceProfile/arn":
            // The profile name is the last path component of the ARN, which is
            // the part anyone reads.
            current?.iamProfile = value.split(separator: "/").last.map(String.init) ?? value
        case "cpuOptions/coreCount":      current?.cores = Int(value)
        case "cpuOptions/threadsPerCore": current?.threadsPerCore = Int(value)
        case "groupSet/item/groupName":
            // Read out, appended, put back: modifying through the optional while
            // reading it is an exclusivity violation.
            var groups = current?.securityGroups ?? []
            groups.append(value)
            current?.securityGroups = groups
        case "tagSet/item/key":           pendingTagKey = value
        case "tagSet/item/value":         pendingTagValue = value
        case "tagSet/item":
            if let key = pendingTagKey {
                current?.tags[key] = pendingTagValue ?? ""
            }
            pendingTagKey = nil
            pendingTagValue = nil
        default: break
        }
    }
}
