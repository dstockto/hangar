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

    /// The heading a host sits under, from the levels the menu is built from.
    ///
    /// `FleetGrouping` decides the same thing for the menubar cascade, and this
    /// has to agree with it or the two disagree about the shape of one fleet.
    /// Empty levels are dropped rather than drawn, for the reason that enum
    /// gives: a level nobody uses is not a level.
    static func heading(_ entry: SearchEntry, keys: [String]) -> String {
        keys.map { entry.instance.tagValue(for: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\u{00B7}")
    }

    /// Product and environment joined the way the *piped* listing shows them.
    ///
    /// Frozen at two levels because `columns` is the shape 0.6.1 printed and
    /// something is parsing it. The heading a person reads is `heading`, which
    /// follows the configured levels instead.
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
            "\(pad(entry.alias, to: aliasWidth))  "
                + "\(pad(group(entry), to: groupWidth))  \(entry.hostname)"
        })
    }

    /// The listing a person reads.
    ///
    /// Falls straight through to `columns` when the destination is not a
    /// terminal, which is what makes this safe to add: every pipeline that
    /// existed before gets the bytes it always got, and the decision is one
    /// place rather than sprinkled through the formatter.
    ///
    /// Grouped only when the fleet is in menu order. A query ranks by relevance,
    /// and headings over a ranked list would either lie about the order or throw
    /// away the ranking, so a search stays flat.
    public static func listing(_ entries: [SearchEntry], terminal: Terminal,
                               grouped: Bool,
                               groupBy keys: [String] = FleetGrouping.defaultLevels)
        -> String {
        guard terminal.isInteractive else { return columns(entries) }
        // A fleet nothing groups gets no headings at all, rather than one
        // "untagged" over the whole thing. FleetGrouping refuses to draw exactly
        // that shape, and a flat ssh_config fleet reaches it.
        let grouped = grouped && entries.contains { !heading($0, keys: keys).isEmpty }
        let indent = grouped ? "  " : ""
        let aliasWidth = min(entries.map(\.alias.count).max() ?? 0, 44)
        let groupWidth = grouped ? 0 : min(entries.map { group($0).count }.max() ?? 0, 28)

        // Bucketed rather than run-detected. The rows arrive in FleetIndex.sortKey
        // order, which is product and env, and the heading follows the configured
        // levels, so the two need not agree: group_by ["Team"] over hosts sorted
        // by product prints platform, infra, platform, severing a group a run
        // detector cannot see it has already closed. FleetGrouping buckets for
        // the same reason.
        var order: [String] = []
        var buckets: [String: [SearchEntry]] = [:]
        for entry in entries {
            let key = grouped ? heading(entry, keys: keys) : ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }

        // Untagged last, which is mistake 23: an empty value sorts first, and a
        // group that says nothing opening the listing is the panel bug again.
        // FleetIndex.sortKey protects the default levels by keying on
        // product.isEmpty, and stops covering it the moment the heading leads
        // with something else, which group_by is free to do.
        if order.count > 1, let untagged = order.firstIndex(of: "") {
            order.append(order.remove(at: untagged))
        }

        var lines: [String] = []
        var shown: String?
        for entry in order.flatMap({ buckets[$0] ?? [] }) {
            if grouped {
                let current = heading(entry, keys: keys)
                if current != shown {
                    if shown != nil { lines.append("") }
                    // A host carrying none of the levels still has to sit under
                    // something a reader can name. Only reachable when other
                    // hosts do carry them, which is FleetGrouping's rule too.
                    lines.append(terminal.styled(current.isEmpty ? "untagged" : current,
                                                 .heading))
                    shown = current
                }
            }
            var row = indent + pad(entry.alias, to: aliasWidth) + "  "
            if !grouped { row += pad(group(entry), to: groupWidth) + "  " }

            // A stopped host says so in words and is dimmed. Never only dimmed:
            // colour that carries the only copy of a fact is a fact some readers
            // do not get.
            let running = entry.instance.state == "running"
            if running {
                row += terminal.styled(entry.hostname, .secondary)
                lines.append(row)
            } else {
                row += entry.hostname + "  " + entry.instance.state
                lines.append(terminal.styled(row, .dimmed))
            }
        }
        return joined(lines)
    }

    /// Right-padded to a column width counted in characters.
    ///
    /// Not `padding(toLength:)`: it counts UTF-16 units while `count` counts
    /// characters, so a value carrying anything outside the basic plane is
    /// measured as longer than the width it is given and gets cut instead of
    /// padded. A cut that lands between an emoji's two halves does not truncate
    /// it, it replaces it with U+FFFD. Tag values come from whoever tags the
    /// account, and turning one into a replacement character is not a column
    /// width problem.
    static func pad(_ text: String, to width: Int) -> String {
        text.count >= width
            ? text
            : text + String(repeating: " ", count: width - text.count)
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

    /// One host as JSON: everything `fields` carries, plus what the cache knows
    /// and a flat string map cannot hold.
    ///
    /// The whole tag map is here because the cache has it and dropping it made
    /// reasonable questions unanswerable: "the m5.large ones", "everything in the
    /// payments ASG". `vcpus` is a number, because a reader filtering on it
    /// should not have to parse a string first.
    ///
    /// `tags` is the map after the configured mapping resolved it, not the raw
    /// one from AWS: the canonical keys carry the resolved value and every other
    /// tag is the fleet's own. That is deliberate, because it is the same map
    /// `-f` filters against, and a document whose tags disagreed with the filters
    /// that read them would be two answers to one question.
    static func jsonFields(_ entry: SearchEntry) -> [String: Any] {
        let instance = entry.instance
        var row: [String: Any] = fields(entry)
        row["type"] = instance.type
        row["launch_time"] = instance.launchTime
        row["asg"] = instance.asg
        row["lifecycle"] = instance.lifecycle ?? ""
        row["private_dns"] = instance.privateDNS ?? ""
        row["tags"] = instance.tags
        // Absent rather than zero: a host whose response did not say how its
        // cores are laid out does not have nought of them.
        if let vcpus = instance.vcpus { row["vcpus"] = vcpus }
        return row
    }

    /// One JSON array, or nil when it could not be encoded, which the caller
    /// reports rather than printing half a document.
    ///
    /// An empty list is `[]`, not nothing. Printing nothing made `jq` downstream
    /// fail on empty input for a query that simply matched no host, which is an
    /// answer rather than a parse error.
    public static func json(_ entries: [SearchEntry]) -> String? {
        // Pretty printing an empty array gives "[\n\n]", which is valid and
        // reads like a bug. Say it in the two characters it takes.
        guard !entries.isEmpty else { return "[]\n" }
        let payload = entries.map(jsonFields)
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

    /// The same hosts, numbered, for "which of these did you mean?".
    ///
    /// Numbered from one because the answer is typed by a person, and every
    /// other list a person is asked to pick from starts there.
    public static func numbered(_ entries: [SearchEntry], terminal: Terminal) -> String {
        let width = String(entries.count).count
        let aliasWidth = min(entries.map(\.alias.count).max() ?? 0, 44)
        let groupWidth = min(entries.map { group($0).count }.max() ?? 0, 28)
        return joined(entries.enumerated().map { index, entry in
            let number = terminal.styled(String(index + 1).leftPadded(to: width + 2),
                                         .heading)
            let state = entry.instance.state == "running" ? "" : "  " + entry.instance.state
            return "\(number)  \(pad(entry.alias, to: aliasWidth))  "
                + "\(pad(group(entry), to: groupWidth))  \(entry.hostname)\(state)"
        })
    }

    // MARK: - Tag keys

    /// The tag keys a fleet uses: name, hosts carrying it, distinct values, and
    /// a few of them, so `-f` stops being a guessing game.
    public static func tagKeys(_ catalog: TagCatalog, shadowed: Set<String> = [],
                               as format: HangarCommand.Format,
                               terminal: Terminal = .plain) -> String? {
        switch format {
        case .alias:
            return joined(catalog.keys.map(\.name))
        case .tsv:
            return joined(catalog.keys.map {
                [$0.name, String($0.instances), String($0.distinctValues),
                 $0.samples.joined(separator: ","),
                 shadowed.contains($0.name) ? "resolved" : ""]
                    .joined(separator: "\t")
            })
        case .json:
            return encode(catalog.keys.map {
                ["key": $0.name, "hosts": $0.instances,
                 "distinct_values": $0.distinctValues, "samples": $0.samples,
                 // True when `-f <key>=` resolves the name instead of reading
                 // this tag, which is the one thing a reader cannot guess.
                 "resolved_by_filter": shadowed.contains($0.name)]
            })
        case .columns:
            let nameWidth = max(min(catalog.keys.map(\.name.count).max() ?? 0, 32),
                                terminal.isInteractive ? 3 : 0)
            var lines = catalog.keys.map { key in
                "\(pad(key.name, to: nameWidth))  "
                    + "\(String(key.instances).leftPadded(to: 6))  "
                    + "\(String(key.distinctValues).leftPadded(to: 7))  "
                    + key.samples.joined(separator: ", ")
            }
            // Four unlabelled columns of numbers need a header, and only a person
            // reading them does. A pipe gets what it always got.
            if terminal.isInteractive, !lines.isEmpty {
                lines.insert(terminal.styled(
                    "\(pad("KEY", to: nameWidth))  \("HOSTS".leftPadded(to: 6))  "
                        + "\("VALUES".leftPadded(to: 7))  EXAMPLES", .heading), at: 0)
            }
            // Which of these names a filter answers differently from the tag,
            // said once under the table rather than as a column, because it
            // applies to a minority of rows. For a person, like the header: a
            // pipe takes the same fact per row from --json or --tsv.
            let resolved = catalog.keys.map(\.name).filter(shadowed.contains)
            if terminal.isInteractive, !resolved.isEmpty {
                lines.append("")
                lines.append("-f resolves these names rather than reading the tag: "
                             + resolved.joined(separator: ", "))
            }
            return joined(lines)
        }
    }

    // MARK: - Tag values

    /// The values one key takes, most-used first, so the next `-f` can be typed
    /// rather than guessed.
    public static func tagValues(_ counts: [TagCatalog.ValueCount],
                                 as format: HangarCommand.Format) -> String? {
        switch format {
        case .alias:
            return joined(counts.map(\.value))
        case .tsv:
            return joined(counts.map { "\($0.value)\t\($0.hosts)" })
        case .json:
            return encode(counts.map { ["value": $0.value, "hosts": $0.hosts] })
        case .columns:
            let width = min(counts.map(\.value.count).max() ?? 0, 44)
            return joined(counts.map {
                "\(pad($0.value, to: width))  \(String($0.hosts).leftPadded(to: 6))"
            })
        }
    }

    /// One array, pretty printed, with the same empty-is-still-a-document rule
    /// the host listing has.
    static func encode(_ payload: [[String: Any]]) -> String? {
        guard !payload.isEmpty else { return "[]\n" }
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

    /// Why nothing came back, naming the set that was actually searched.
    ///
    /// Mistake 26: a number on screen has to name the set it counted. "The
    /// cached fleet is empty" was said whenever the query was empty, so a filter
    /// that matched nothing sent the reader off to refresh a fleet that was
    /// already there and already full.
    public static func nothingMatched(query: String, filters: Int,
                                      fleetSize: Int) -> String {
        guard fleetSize > 0 else { return "the cached fleet is empty." }
        let clause = filters == 1 ? "that filter" : "those \(filters) filters"
        guard !query.isEmpty else {
            // A fleet with hosts in it cannot come back empty from no query and
            // no filter, so say the true thing rather than count filters nobody
            // passed.
            return filters > 0
                ? "no host matched \(clause), out of \(fleetSize)."
                : "no host matched, out of \(fleetSize)."
        }
        let narrowed = filters > 0 ? " with \(clause)" : ""
        return "nothing matched \"\(query)\"\(narrowed) in \(fleetSize) hosts."
    }

    /// Nothing prints as nothing, not as a blank line.
    static func joined(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

extension String {
    /// Right-aligned in a fixed column, so counts line up under each other.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
