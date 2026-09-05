import Foundation

/// The fleet as text, in the shapes the `hangar` command prints.
///
/// Returns strings rather than printing them, which is the whole reason it is
/// here: the suite can assert on bytes, and `main.swift` does the writing.
/// Every shape carries its own trailing newline, so a caller writes it as it is.
public enum FleetOutput {

    /// One host flattened to the names the other formats and the documentation
    /// use. Strings throughout, because this is what fills columns and TSV.
    public static func fields(_ entry: SearchEntry) -> [String: String] {
        let instance = entry.instance
        return [
            "alias": entry.alias,
            "hostname": entry.hostname,
            "product": instance.product,
            "env": instance.env,
            "env_name": instance.envName,
            "role": instance.role,
            "id": instance.id,
            "state": instance.state,
            "private_ip": instance.privateIP ?? "",
            "public_ip": instance.publicIP ?? "",
            "zone": instance.availabilityZone ?? "",
            "source": instance.origin.label,
            "command": "ssh \(entry.alias)",
        ]
    }

    /// Product and environment joined the way the listing shows them.
    static func group(_ entry: SearchEntry) -> String {
        [entry.instance.product, entry.instance.env]
            .filter { !$0.isEmpty }.joined(separator: "\u{00B7}")
    }

    /// The listing: alias, group, hostname, in columns wide enough for the widest
    /// of each, capped so one long alias does not indent the whole fleet.
    public static func columns(_ entries: [SearchEntry]) -> String {
        let aliasWidth = min(entries.map(\.alias.count).max() ?? 0, 44)
        let groupWidth = min(entries.map { group($0).count }.max() ?? 0, 28)
        return joined(entries.map { entry in
            let alias = entry.alias.padding(toLength: max(aliasWidth, entry.alias.count),
                                            withPad: " ", startingAt: 0)
            let where_ = group(entry)
            let padded = where_.padding(toLength: max(groupWidth, where_.count),
                                        withPad: " ", startingAt: 0)
            return "\(alias)  \(padded)  \(entry.hostname)"
        })
    }

    /// Aliases and nothing else, one per line, which is the shape a `while read`
    /// loop and `xargs` both want: one token per line, no columns to cut out of.
    public static func aliases(_ entries: [SearchEntry]) -> String {
        joined(entries.map(\.alias))
    }

    /// Six fixed columns, tab separated, so `cut -f` and `awk -F'\t'` can take one
    /// by number. Fixed rather than every field: the order is the documented part.
    public static func tsv(_ entries: [SearchEntry]) -> String {
        joined(entries.map { entry in
            let row = fields(entry)
            return ["alias", "hostname", "product", "env", "state", "id"]
                .map { row[$0] ?? "" }.joined(separator: "\t")
        })
    }

    /// One JSON array, or nil when it could not be encoded, which the caller
    /// reports rather than printing half a document.
    public static func json(_ entries: [SearchEntry]) -> String? {
        let payload = entries.map(fields)
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

    /// The shape a parsed command asked for.
    public static func rendered(_ entries: [SearchEntry],
                                as format: HangarCommand.Format) -> String? {
        switch format {
        case .columns: return columns(entries)
        case .alias:   return aliases(entries)
        case .tsv:     return tsv(entries)
        case .json:    return json(entries)
        }
    }

    /// Nothing prints as nothing, not as a blank line.
    static func joined(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
