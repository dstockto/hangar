import Foundation

/// Hosts the user brought themselves, from `~/.hangar/hosts.csv`.
///
/// A plain CSV rather than an import wizard with a database behind it, so a
/// script, a cron job, an Ansible inventory export or a Netbox query can all
/// feed it, and the user can read what Hangar is about to do before it does it.
/// Importing a CSV means copying it here; there is no other state.
public enum HostsFile {

    public struct Result: Sendable {
        public var hosts: [Instance]
        /// Rows that were refused, each naming its line. A count alone sends
        /// someone hunting through a spreadsheet for a row Hangar already found.
        public var skipped: [String]
    }

    /// Columns with a meaning. Everything else becomes a tag under its own
    /// header, so a fleet with `datacenter` or `owner` columns keeps them and
    /// can group the menu by them.
    static let known: Set<String> = [
        "alias", "name", "hostname", "host", "address", "ip",
        "user", "username", "login", "port",
        "product", "service", "app", "env", "environment", "role", "state",
    ]

    public static func load(path: String = HangarConfig.hostsFilePath) -> Result {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Result(hosts: [], skipped: [])
        }
        let result = parse(text)
        Log.info(.fleet, "hosts file read",
                 ["hosts": "\(result.hosts.count)", "skipped": "\(result.skipped.count)"])
        return result
    }

    /// Copies a CSV into place, so drag and drop and the file on disk are the
    /// same thing. Parsed first: a file that produces no hosts at all is a
    /// mistake worth reporting before it replaces one that worked.
    public static func install(from url: URL,
                               to path: String = HangarConfig.hostsFilePath) throws -> Result {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = parse(text)
        guard !parsed.hosts.isEmpty else {
            throw HangarError.malformedResponse(
                parsed.skipped.first
                    ?? "no hosts in \(url.lastPathComponent). It needs a header row "
                     + "with at least an alias or hostname column.")
        }
        guard PrivateFile.write(Data(text.utf8), to: path) else {
            throw HangarError.malformedResponse("could not write \(path)")
        }
        Log.info(.fleet, "hosts file installed", ["hosts": "\(parsed.hosts.count)"])
        return parsed
    }

    // MARK: - Parsing

    public static func parse(_ text: String) -> Result {
        var rows = splitRows(text)
        var skipped: [String] = []
        guard !rows.isEmpty else { return Result(hosts: [], skipped: []) }

        let header = rows.removeFirst().0.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard header.contains(where: { known.contains($0) }) else {
            return Result(hosts: [], skipped: [
                "line 1: no recognised column. The header needs at least alias or hostname."])
        }

        var hosts: [Instance] = []
        var seen = Set<String>()
        for (fields, line) in rows {
            var values: [String: String] = [:]
            for (index, column) in header.enumerated() where index < fields.count {
                let value = fields[index].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { values[column] = value }
            }
            guard !values.isEmpty else { continue }

            let hostname = first(values, "hostname", "host", "address", "ip")
            guard let alias = first(values, "alias", "name") ?? hostname else {
                skipped.append("line \(line): no alias and no hostname")
                continue
            }
            // An alias with no address is one ssh resolves itself, which is how
            // people list real DNS names in a spreadsheet.
            let target = hostname ?? alias
            guard SSHConfigValue.isSafeAlias(alias) else {
                skipped.append("line \(line): '\(SSHConfigValue.comment(alias))' "
                    + "cannot be an ssh alias")
                continue
            }
            guard SSHConfigValue.isEmittable(target) else {
                skipped.append("line \(line): '\(alias)' has a hostname ssh cannot be given")
                continue
            }
            guard seen.insert(alias.lowercased()).inserted else {
                skipped.append("line \(line): '\(alias)' repeats an earlier row")
                continue
            }

            var tags: [String: String] = ["Name": alias, "hostname": target]
            if let value = first(values, "product", "service", "app") { tags["product"] = value }
            if let value = first(values, "env", "environment") { tags["env"] = value }
            if let value = values["role"] { tags["Name"] = value }
            if let value = first(values, "user", "username", "login") {
                tags["ssh_config_user"] = value
            }
            if let value = values["port"] { tags["ssh_config_port"] = value }
            // Anything the header named that Hangar has no meaning for is kept
            // as its own tag, so it can be searched, grouped and matched on.
            for (column, value) in values where !known.contains(column) {
                tags[column] = value
            }

            hosts.append(Instance(
                id: "csv:\(alias)", state: values["state"] ?? "unknown", type: "",
                privateIP: nil, publicIP: nil, availabilityZone: nil,
                launchTime: "", tags: tags,
                source: .hostsFile, preferredAlias: alias))
        }
        return Result(hosts: hosts, skipped: skipped)
    }

    static func first(_ values: [String: String], _ columns: String...) -> String? {
        for column in columns {
            if let value = values[column], !value.isEmpty { return value }
        }
        return nil
    }

    /// Rows with their 1-based line numbers, handling the quoting a spreadsheet
    /// produces: a quoted field may contain commas and newlines, and a doubled
    /// quote inside one means a literal quote.
    static func splitRows(_ text: String) -> [([String], Int)] {
        var rows: [([String], Int)] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var rowStart = 1
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { fields.append(field); field = "" }
        func endRow() {
            endField()
            let isBlank = fields.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            let isComment = fields.first?.trimmingCharacters(in: .whitespaces)
                .hasPrefix("#") ?? false
            if !isBlank && !isComment { rows.append((fields, rowStart)) }
            fields = []
            rowStart = line
        }

        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    if ch.isNewline { line += 1 }
                    field.append(ch)
                }
                continue
            }
            // isNewline rather than a match on "\n": Swift reads a CRLF pair as
            // one character, so a file exported from a spreadsheet on Windows
            // matched neither branch and every row ran into the next.
            if ch.isNewline {
                line += 1
                endRow()
                continue
            }
            switch ch {
            case "\"": inQuotes = true
            case ",":  endField()
            default:   field.append(ch)
            }
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }
        return rows
    }

    /// The header a person should write, shown on the setup screen and written
    /// as a starter file so nobody has to guess the column names.
    public static let example = """
    alias,hostname,user,port,product,env,role
    payments-prod-web-1,10.0.4.11,ec2-user,22,payments,prod,web
    payments-prod-db-1,10.0.4.20,ec2-user,22,payments,prod,db
    """
}
