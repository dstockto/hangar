import Foundation
import HangarCore

// The fleet Hangar already knows, on the command line, so tmux, fzf, herder and
// anything else that can run a program can reach the same hosts the panel does.
//
// It reads ~/.hangar/cache and nothing else: no AWS call, no credentials, no
// network, which is what makes it fast enough to put behind a keystroke. The
// menubar app is what refreshes that cache.
//
// Parsing and formatting are in HangarCore, where the suite can reach them. What
// is left here is the part that talks to the process: files, streams, exit codes.

// MARK: - Output

func stderrLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Written rather than printed because every shape carries its own trailing
/// newline, and nothing at all prints nothing rather than a blank line.
func write(_ text: String) {
    guard !text.isEmpty else { return }
    FileHandle.standardOutput.write(Data(text.utf8))
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

// MARK: - Run

let command = HangarCommand.parse(Array(CommandLine.arguments.dropFirst()))

if let problem = command.problem {
    stderrLine("hangar: \(problem)")
    stderrLine("Try 'hangar --help'.")
    exit(64)
}
if command.help { print(usage); exit(0) }
if command.version { print(version()); exit(0) }

let cachePath = command.cache ?? HangarConfig.cachePath
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

let query = Fuzzy.Query(command.searchText)
var matched = FleetIndex.ranked(FleetIndex.filtered(all, by: command.filters.isEmpty
                                                        ? nil : command.filters),
                                matching: query)
if let limit = command.limit { matched = Array(matched.prefix(limit)) }

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
        : "hangar: nothing matched \"\(command.searchText)\" in \(all.count) hosts.")
    exit(1)
}

guard let text = FleetOutput.rendered(matched, as: command.format) else {
    stderrLine("hangar: could not encode the fleet as JSON")
    exit(2)
}
write(text)
