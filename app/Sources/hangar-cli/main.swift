import Foundation
import HangarCore

// The fleet Hangar already knows, on the command line, so tmux, fzf, herder and
// anything else that can run a program can reach the same hosts the panel does.
//
// It reads ~/.hangar/cache and nothing else: no AWS call, no credentials, no
// network, which is what makes it fast enough to put behind a keystroke. The
// menubar app is what refreshes that cache.

// MARK: - Arguments

struct Options {
    enum Format { case columns, alias, tsv, json }

    var query: [String] = []
    var format: Format = .columns
    var limit: Int?
    var filters: [String: String] = [:]
    var cache: String?
    var help = false
    var version = false
    var problem: String?
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        index += 1
        func value(_ flag: String) -> String? {
            guard index < arguments.endIndex else {
                options.problem = "\(flag) needs a value"
                return nil
            }
            defer { index += 1 }
            return arguments[index]
        }
        switch argument {
        case "-s", "--search":
            if let text = value(argument) { options.query.append(text) }
        case "-a", "--alias", "--aliases":
            options.format = .alias
        case "--tsv":
            options.format = .tsv
        case "--json":
            options.format = .json
        case "-l", "--list":
            break   // The list is an empty query, so this is the default already.
        case "-n", "--limit":
            guard let text = value(argument) else { break }
            guard let count = Int(text), count > 0 else {
                options.problem = "--limit needs a positive number, not '\(text)'"
                break
            }
            options.limit = count
        case "-f", "--filter":
            guard let text = value(argument) else { break }
            let parts = text.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty else {
                options.problem = "--filter takes key=value, not '\(text)'"
                break
            }
            options.filters[String(parts[0])] = String(parts[1])
        case "--cache":
            if let text = value(argument) { options.cache = text }
        case "-h", "--help":
            options.help = true
        case "-V", "--version":
            options.version = true
        default:
            // A stray flag is a mistake worth reporting. Anything else is part of
            // the query, so `hangar web prod` works without -s.
            if argument.hasPrefix("-") && argument != "-" {
                options.problem = "unknown option '\(argument)'"
            } else {
                options.query.append(argument)
            }
        }
    }
    return options
}

// MARK: - Output

func stderrLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// The version of the app this binary shipped inside, read from the bundle it
/// sits in rather than repeated here, so it cannot drift from Info.plist.
func version() -> String {
    // Bundle.main.executablePath, not argv[0]: a shell that found this on the
    // PATH passes the bare command name, and a path relative to the working
    // directory resolves to nothing, which reported every install as a
    // development build.
    let executable = URL(fileURLWithPath: Bundle.main.executablePath
                            ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let plist = executable
        .deletingLastPathComponent()      // Helpers
        .deletingLastPathComponent()      // Contents
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any],
          let short = info["CFBundleShortVersionString"] as? String
    else { return "development" }
    return short
}

let usage = """
hangar \(version()) - the fleet Hangar already knows, on the command line

USAGE
  hangar                     every host, in the order the menu lists them
  hangar <query>             hosts matching a fuzzy query, best match first
  hangar -s <query>          the same, spelled out

OUTPUT
  -a, --alias                aliases alone, one per line
      --tsv                  alias, hostname, product, env, state, id
      --json                 one JSON array
  -n, --limit <n>            at most n hosts
  -f, --filter <key=value>   only hosts carrying that tag, wildcards allowed
      --cache <path>         read this cache instead of ~/.hangar/cache

  -h, --help                 this
  -V, --version              the version of Hangar this shipped with

EXAMPLES
  ssh "$(hangar -a -s 'web prod' | head -1)"
  hangar | fzf | awk '{print $1}' | xargs ssh
  tmux new-window "ssh $(hangar -a db-prod | head -1)"
  hangar --json -f env=prod | jq -r '.[].hostname'

The list comes from ~/.hangar/cache, which the Hangar app refreshes. Nothing
here calls AWS, so it costs no credential and no network round trip.

EXIT
  0  hosts were printed
  1  nothing matched
  2  no fleet cached yet
"""

func fields(_ entry: SearchEntry) -> [String: String] {
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

func printColumns(_ entries: [SearchEntry]) {
    let aliasWidth = min(entries.map(\.alias.count).max() ?? 0, 44)
    let group = { (entry: SearchEntry) -> String in
        [entry.instance.product, entry.instance.env]
            .filter { !$0.isEmpty }.joined(separator: "\u{00B7}")
    }
    let groupWidth = min(entries.map { group($0).count }.max() ?? 0, 28)
    for entry in entries {
        let alias = entry.alias.padding(toLength: max(aliasWidth, entry.alias.count),
                                        withPad: " ", startingAt: 0)
        let where_ = group(entry)
        let padded = where_.padding(toLength: max(groupWidth, where_.count),
                                    withPad: " ", startingAt: 0)
        print("\(alias)  \(padded)  \(entry.hostname)")
    }
}

func printTSV(_ entries: [SearchEntry]) {
    for entry in entries {
        let row = fields(entry)
        print([row["alias"], row["hostname"], row["product"], row["env"],
               row["state"], row["id"]]
            .map { $0 ?? "" }.joined(separator: "\t"))
    }
}

func printJSON(_ entries: [SearchEntry]) {
    let payload = entries.map(fields)
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        stderrLine("hangar: could not encode the fleet as JSON")
        exit(2)
    }
    print(text)
}

// MARK: - Run

let options = parse(Array(CommandLine.arguments.dropFirst()))

if let problem = options.problem {
    stderrLine("hangar: \(problem)")
    stderrLine("Try 'hangar --help'.")
    exit(64)
}
if options.help { print(usage); exit(0) }
if options.version { print(version()); exit(0) }

let cachePath = options.cache ?? HangarConfig.cachePath
guard let cache = FleetCache.load(path: cachePath) else {
    stderrLine("hangar: no fleet cached yet at \(cachePath).")
    stderrLine("Open Hangar once and let it refresh, then try again.")
    exit(2)
}

let config = (try? HangarConfig.load()) ?? .standard()
// Re-normalized on load for the same reason the app does it: the tag mapping may
// have changed since the cache was written.
let instances = config.tagMapping.normalize(cache.instances)
let all = FleetIndex.entries(for: instances, config: config)

let query = Fuzzy.Query(options.query.joined(separator: " ")
    .trimmingCharacters(in: .whitespaces))
var matched = FleetIndex.ranked(FleetIndex.filtered(all, by: options.filters.isEmpty
                                                        ? nil : options.filters),
                                matching: query)
if let limit = options.limit { matched = Array(matched.prefix(limit)) }

// Said once, on stderr, so a pipeline is unaffected but nobody is left wondering
// why the list is short or the aliases do not resolve.
let hours = Double(config.healthyWithinHours ?? 24)
if cache.age > hours * 3600 {
    let days = Int(cache.age / 86_400)
    let age = days >= 1 ? "\(days) day\(days == 1 ? "" : "s")"
                        : "\(Int(cache.age / 3600)) hours"
    stderrLine("hangar: the cached fleet is \(age) old; open Hangar to refresh it.")
}
if !SSHConfigWriter.includeLinePresent() {
    stderrLine("hangar: ~/.ssh/config has no Include for Hangar's aliases, so "
               + "'ssh <alias>' will not resolve. Setup Check can add it.")
}

guard !matched.isEmpty else {
    stderrLine(query.isEmpty
        ? "hangar: the cached fleet is empty."
        : "hangar: nothing matched \"\(options.query.joined(separator: " "))\" "
            + "in \(all.count) hosts.")
    exit(1)
}

switch options.format {
case .columns: printColumns(matched)
case .alias:   for entry in matched { print(entry.alias) }
case .tsv:     printTSV(matched)
case .json:    printJSON(matched)
}
