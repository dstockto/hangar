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

/// The one way this program writes to stdout.
///
/// One way on purpose. `print` goes through stdio, which block-buffers whenever
/// stdout is not a terminal, and this is an unbuffered write on the descriptor:
/// mixing them lets output arrive in an order neither one chose, in a pipe,
/// which is exactly where nobody looks. Every shape also carries its own
/// trailing newline, so nothing at all prints nothing rather than a blank line.
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

COMMANDS
  hangar ssh <query>         connect to the one matching host
  hangar tags                the tag keys this fleet uses, and how many carry each
  hangar values <key>        the values one key takes, most used first

  A command is the first plain word on the line. To search for a host named
  after one, use 'hangar -s tags' or 'hangar -- tags'.

OUTPUT
  -a, --alias                aliases alone, one per line
      --tsv                  alias, hostname, product, env, state, id
      --json                 one JSON array, always valid, [] when nothing matched
  -n, --limit <n>            at most n hosts
  -1, --first                take the best match without asking
      --dry-run              print what would run, and run nothing
  -f, --filter <key=value>   only hosts whose tag matches; repeat to narrow
                             key=a,b any of them   key!=a none of them
                             * is a wildcard, so quote it in zsh; \\, is a comma
                             keys: any tag, plus name, state, id, asg, env_name
      --cache <path>         read this cache instead of ~/.hangar/cache

  -h, --help                 this
  -V, --version              the version of Hangar this shipped with

EXAMPLES
  ssh "$(hangar -a -s 'web prod' | head -1)"
  hangar | fzf | awk '{print $1}' | xargs ssh
  tmux new-window "ssh $(hangar -a db-prod | head -1)"
  hangar --json -f env=prod | jq -r '.[].hostname'
  hangar -f env=prod,staging -f 'name!=*canary*' -f state=running
  hangar tags && hangar values env
  hangar ssh web prod
  hangar ssh -1 db-prod

The list comes from ~/.hangar/cache, which the Hangar app refreshes. Nothing
here calls AWS, so it costs no credential and no network round trip.

EXIT
  0  hosts were printed, or the work finished
  1  nothing matched
  2  no fleet cached yet
  3  more than one host matched and none was chosen
"""

// MARK: - Run

let command = HangarCommand.parse(Array(CommandLine.arguments.dropFirst()))
// Asked once, here, so every formatter is handed the answer rather than each
// one deciding for itself what the other end of the pipe is.
let terminal = Terminal.standardOutput()

if let problem = command.problem {
    stderrLine("hangar: \(problem)")
    stderrLine("Try 'hangar --help'.")
    exit(64)
}
if command.help { write(usage + "\n"); exit(0) }
if command.version { write(version() + "\n"); exit(0) }

/// An empty answer in the shape that was asked for.
///
/// FleetOutput decides what empty looks like in each format, rather than this
/// file carrying a second copy of which ones are machine readable. A format
/// that prints nothing at all bottoms out in write's own guard.
func writeEmptyResult() {
    write(FleetOutput.rendered([], as: command.format) ?? "")
}

let cachePath = command.cache ?? HangarConfig.cachePath
guard let cache = FleetCache.load(path: cachePath) else {
    // A document here too. No cache is the first thing a fresh install hits, so
    // it is the likeliest place a first --json pipeline runs, and printing
    // nothing is the jq-on-empty-input failure this format exists to avoid.
    writeEmptyResult()
    stderrLine("hangar: no fleet cached yet at \(cachePath).")
    stderrLine("Open Hangar once and let it refresh, then try again.")
    exit(2)
}

let config = (try? HangarConfig.load()) ?? .standard()
// Re-normalized on load for the same reason the app does it: the tag mapping may
// have changed since the cache was written.
let instances = config.tagMapping.normalize(cache.instances)

// Said once, on stderr, so a pipeline is unaffected but nobody is left wondering
// why the list is short.
let hours = Double(config.healthyWithinHours ?? 24)
if cache.age > hours * 3600 {
    let days = Int(cache.age / 86_400)
    let age = days >= 1 ? "\(days) day\(days == 1 ? "" : "s")"
                        : "\(Int(cache.age / 3600)) hours"
    stderrLine("hangar: the cached fleet is \(age) old; open Hangar to refresh it.")
}

/// Nothing to print is not the same failure for every command, so each one says
/// what it found nothing of.
func emit(_ text: String?, orElse complaint: String, empty: Bool) -> Never {
    guard let text else {
        stderrLine("hangar: could not encode that as JSON")
        exit(2)
    }
    write(text)
    if empty {
        stderrLine(complaint)
        exit(1)
    }
    exit(0)
}

switch command.verb {
case .tags:
    // The fleet's own keys, before normalization. Discovering from the normalized
    // fleet listed every grouping key twice, because normalize writes the
    // canonical key and keeps the original, so a fleet tagged Environment saw
    // both `Environment` and `env` with identical counts. It bought no agreement
    // with `-f` either, and the marker below says which keys actually answer
    // differently on this fleet rather than promising an agreement.
    let catalog = TagCatalog.discover(from: cache.instances)
    // Which keys a filter answers differently from the tag, asked of this fleet
    // rather than assumed from a list of names.
    let shadowed = TagCatalog.shadowedKeys(among: catalog.keys.map(\.name),
                                           raw: cache.instances, resolved: instances)
    emit(FleetOutput.tagKeys(catalog, shadowed: shadowed, as: command.format,
                             terminal: terminal),
         orElse: "hangar: no host in the cached fleet carries a tag.",
         empty: catalog.isEmpty)

case .values:
    guard let key = command.valuesKey else { exit(64) }   // parse already reported
    let counts = TagCatalog.values(of: key, in: instances)
    emit(FleetOutput.tagValues(counts, as: command.format),
         orElse: "hangar: no host carries a '\(key)' tag. Try 'hangar tags'.",
         empty: counts.isEmpty)

case .list, .ssh:
    // Both need the matched hosts below; ssh then picks one of them.
    break
}

let all = FleetIndex.entries(for: instances, config: config)

let query = Fuzzy.Query(command.searchText)
var matched = FleetIndex.ranked(FleetIndex.filtered(all, by: command.filters),
                                matching: query)
if let limit = command.limit { matched = Array(matched.prefix(limit)) }

// Only for a listing, whose whole point is aliases you then ssh to. A tag key
// does not stop being true because ssh_config lacks an Include.
if !SSHConfigWriter.includeLinePresent() {
    stderrLine("hangar: ~/.ssh/config has no Include for Hangar's aliases, so "
               + "'ssh <alias>' will not resolve. Setup Check can add it.")
}

guard !matched.isEmpty else {
    // Nothing matching is an answer, and printing nothing made jq downstream
    // fail on empty input for a query that was simply specific. The exit code
    // still says nothing matched.
    writeEmptyResult()
    stderrLine("hangar: " + FleetOutput.nothingMatched(
        query: command.searchText, filters: command.filters.count,
        fleetSize: all.count))
    exit(1)
}

if command.verb == .ssh {
    let chosen: SearchEntry
    if matched.count == 1 || command.first {
        chosen = matched[0]
    } else if isatty(0) == 1 {
        // Asked on stderr so that --dry-run piped somewhere still writes only
        // the command to stdout.
        stderrLine("hangar: \(matched.count) hosts match "
                   + "\"\(command.searchText)\". Which one?")
        FileHandle.standardError.write(
            Data(FleetOutput.numbered(matched, terminal: Terminal.standardError()).utf8))
        FileHandle.standardError.write(Data("Number, or Return to cancel: ".utf8))
        guard let index = Chooser.choice(readLine(), count: matched.count) else {
            stderrLine("hangar: nothing chosen.")
            exit(3)
        }
        chosen = matched[index]
    } else {
        // Nobody to ask. A script or an agent has to be specific, or say so with
        // --first, rather than have a host picked for it.
        stderrLine("hangar: \(matched.count) hosts match "
                   + "\"\(command.searchText)\". Narrow it, or use --first.")
        FileHandle.standardError.write(
            Data(FleetOutput.numbered(matched, terminal: .plain).utf8))
        exit(3)
    }

    // The bare alias, which is what the listing's own `command` field has always
    // advertised: ssh_config already carries the user, the key and the ProxyJump.
    let vector = SSHCommand.arguments(target: chosen.alias, user: nil,
                                      identityFile: nil, managedByConfig: true)
    if command.dryRun {
        print(SSHCommand.line(target: chosen.alias, user: nil,
                              identityFile: nil, managedByConfig: true))
        exit(0)
    }
    // Replaced rather than spawned: ssh then owns the terminal, signals reach it
    // rather than us, and its exit status is this command's without being copied.
    var vectorC: [UnsafeMutablePointer<CChar>?] = vector.map { strdup($0) }
    vectorC.append(nil)
    execv("/usr/bin/ssh", &vectorC)
    stderrLine("hangar: could not run /usr/bin/ssh: \(String(cString: strerror(errno)))")
    exit(2)
}

// The one shape that differs by reader. Everything else is the same bytes for
// a person and a program, because everything else is already what a program
// asked for by name.
let listing: String? = command.format == .columns
    ? FleetOutput.listing(matched, terminal: terminal, grouped: query.isEmpty,
                          groupBy: config.groupingKeys)
    : FleetOutput.rendered(matched, as: command.format)

guard let text = listing else {
    stderrLine("hangar: could not encode the fleet as JSON")
    exit(2)
}
write(text)
