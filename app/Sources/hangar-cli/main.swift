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

/// Runs one vector per host, at most `parallel` at a time, and returns the exit
/// code for the whole job.
///
/// **Ctrl-C does not stop the children.** Foundation starts each in its own
/// process group, so a SIGINT the terminal generates for the foreground group
/// reaches this process and not them: the prompt comes back and the commands
/// keep running, reparented to init. `--timeout` does not cover it: the deadline
/// is enforced by the loop below, so it dies with us and the orphan runs
/// unbounded. It bounds a run left alone, not one interrupted.
/// Fixing it means a DispatchSource signal source, which runs outside
/// signal-handler context and can hold a lock around the live list, plus
/// SIG_IGN so the default disposition does not kill us first. That is a change
/// to how this program handles signals, which it currently does not do at all,
/// so it wants its own intent rather than a hurried addition here.
///
/// Output goes to a file per host rather than a pipe. Reading a pipe after the
/// process ends deadlocks on anything larger than the buffer, and unlike the
/// helpers `ProcessRunner` was written for, this runs whatever the user asked
/// for and has no idea how much it will say.
///
/// At one at a time the child inherits this process's streams instead, so an
/// interactive program works and output is live.
/// A deadline as a person wrote it: --timeout 0.5 is not "0 seconds".
func seconds(_ value: Double) -> String {
    let rounded = value.rounded()
    let text = abs(value - rounded) < 0.001 ? String(Int(rounded)) : String(value)
    return "\(text) second\(text == "1" ? "" : "s")"
}

func run(_ vectors: [[String]], aliases: [String],
         parallel: Int, timeout: Double?) -> Int32 {
    guard let program = vectors.first?.first else { return 0 }
    let streaming = parallel == 1
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hangar-exec-\(ProcessInfo.processInfo.processIdentifier)")
    if !streaming {
        try? FileManager.default.createDirectory(at: scratch,
                                                 withIntermediateDirectories: true)
    }
    defer { if !streaming { try? FileManager.default.removeItem(at: scratch) } }

    struct Running {
        var process: Process
        var alias: String
        var log: URL?
        var startedAt: Date
        /// Set once the deadline has fired, so the next pass escalates rather
        /// than sending a second SIGTERM and printing the message again.
        var signalledAt: Date?
    }

    var next = 0
    var live: [Running] = []
    var failures = 0

    func start(_ index: Int) {
        let process = Process()
        // Resolved on PATH rather than assumed: the program is the user's, and
        // herdr, tmux and ssh do not agree on where they live.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = vectors[index]
        var log: URL?
        if streaming {
            // The terminal's stdin, so an interactive command works: one at a
            // time is a session you sit in, not a fan-out. Above one they get
            // /dev/null instead, because eight children sharing one keyboard is
            // not something a person can answer.
            process.standardInput = FileHandle.standardInput
        } else {
            let path = scratch.appendingPathComponent("\(index).log")
            FileManager.default.createFile(atPath: path.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: path) {
                process.standardOutput = handle
                process.standardError = handle
            }
            process.standardInput = FileHandle.nullDevice
            log = path
        }
        do {
            try process.run()
            live.append(Running(process: process, alias: aliases[index], log: log,
                                startedAt: Date(), signalledAt: nil))
        } catch {
            stderrLine("hangar: \(aliases[index]): could not run \(program): "
                       + error.localizedDescription)
            failures += 1
        }
    }

    func finish(_ entry: Running) {
        let status = entry.process.terminationStatus
        if let log = entry.log {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            write("== \(entry.alias)\(status == 0 ? "" : "  exit \(status)") ==\n")
            if !text.isEmpty { write(text.hasSuffix("\n") ? text : text + "\n") }
        } else if status != 0 {
            stderrLine("hangar: \(entry.alias): exit \(status)")
        }
        if status != 0 { failures += 1 }
    }

    while next < vectors.count || !live.isEmpty {
        while live.count < parallel && next < vectors.count {
            start(next)
            next += 1
        }
        guard !live.isEmpty else { continue }
        // Polled rather than waited on, because several are outstanding and the
        // one that finishes first is not known in advance.
        var still: [Running] = []
        for var entry in live {
            if let timeout, entry.process.isRunning {
                if let signalled = entry.signalledAt {
                    // SIGTERM is a request. A command that traps it, which is
                    // exactly what a shell wrapper does, ignores it forever, so
                    // the deadline needs something it cannot decline.
                    if Date().timeIntervalSince(signalled) > 2 {
                        kill(entry.process.processIdentifier, SIGKILL)
                    }
                } else if Date().timeIntervalSince(entry.startedAt) > timeout {
                    entry.process.terminate()
                    entry.signalledAt = Date()
                    stderrLine("hangar: \(entry.alias): did not finish within "
                               + "\(seconds(timeout))")
                }
            }
            if entry.process.isRunning { still.append(entry) } else { finish(entry) }
        }
        live = still
        if !live.isEmpty { usleep(20_000) }
    }
    return failures == 0 ? 0 : 4
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

RUNNING SOMETHING PER HOST
      --exec <program> ...   run this once per matched host. Takes the rest of
                             the line. {alias} {hostname} {id} {private_ip}
                             {public_ip} {product} {env} {env_name} {role}
                             {state} {type} {zone} {asg} are replaced per
                             argument, never through a shell. Prefer {alias}:
                             it is the only one that cannot look like a flag
      --parallel <n>         how many at once, default 1
      --timeout <seconds>    how long each one gets, default forever
  -y, --yes                  agree to a fan-out in advance. Required when more
                             than one host matches and there is no terminal
  -f, --filter <key=value>   only hosts whose tag matches; repeat to narrow
                             key=a,b any of them   key!=a none of them
                             * is a wildcard, so quote it in zsh; \\, is a comma
                             keys: any tag, plus name, state, id, asg, env_name
      --cache <path>         read this cache instead of ~/.hangar/cache
      --config <path>        read this config instead of ~/.hangar/config.json,
                             and write none

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
  hangar -f env=prod web --exec herdr pane new --cmd 'ssh {alias}'
  hangar -f env=prod --parallel 8 -y --exec ssh {alias} uptime

The list comes from ~/.hangar/cache, which the Hangar app refreshes. Nothing
here calls AWS, so it costs no credential and no network round trip.

EXIT
  0  hosts were printed, or the work finished
  1  nothing matched
  2  no fleet cached yet
  3  more than one host matched and none was chosen
  4  a command run with --exec failed on at least one host
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

// An explicit path is read and never created, so pointing this at somebody
// else's directory, or at a testbed's, leaves nothing behind.
//
// Fatal when it cannot be read, the way --cache already is. `.map { try? … }`
// made a bad path fall all the way through to the defaults, silently, and the
// defaults rewrite every canonical tag: the aliases printed were ones that do
// not exist in the user's ssh_config.
let config: HangarConfig
if let path = command.config {
    do {
        config = try HangarConfig.read(from: path)
    } catch {
        stderrLine("hangar: \(error.localizedDescription)")
        exit(2)
    }
} else {
    config = (try? HangarConfig.load()) ?? .standard()
}
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

if !command.exec.isEmpty {
    var vectors: [[String]] = []
    var aliases: [String] = []
    var refused = 0
    for (entry, planned) in zip(matched, ExecPlan.plans(command.exec, for: matched)) {
        switch planned {
        case .run(let vector):
            vectors.append(vector)
            aliases.append(entry.alias)
        case .refuse(let why):
            stderrLine("hangar: \(entry.alias): \(why)")
            refused += 1
        }
    }
    guard !vectors.isEmpty else {
        stderrLine("hangar: nothing left to run on.")
        exit(4)
    }

    if command.dryRun {
        write(vectors.map(ExecPlan.readable).joined(separator: "\n") + "\n")
        exit(refused == 0 ? 0 : 4)
    }

    switch ExecPlan.consent(hosts: vectors.count, alreadyGiven: command.yes,
                            canAsk: isatty(0) == 1
                                && Terminal.standardError().isInteractive) {
    case .granted:
        break
    case .needsExplicitYes(let hosts):
        stderrLine("hangar: this would run on \(hosts) hosts and there is no "
                   + "terminal to ask. Pass -y if you meant to.")
        exit(64)
    case .ask(let hosts):
        stderrLine("hangar: run this on \(hosts) hosts?")
        stderrLine("  " + ExecPlan.readable(command.exec))
        for alias in aliases.prefix(10) { stderrLine("  " + alias) }
        if aliases.count > 10 { stderrLine("  and \(aliases.count - 10) more") }
        FileHandle.standardError.write(Data("Type y to run: ".utf8))
        guard ExecPlan.agrees(readLine()) else {
            stderrLine("hangar: nothing run.")
            exit(3)
        }
    }

    let status = run(vectors, aliases: aliases,
                     parallel: command.parallel, timeout: command.timeout)
    exit(status != 0 || refused > 0 ? 4 : 0)
}

if command.verb == .ssh {
    // Both halves of a conversation: something to read the question and
    // something to answer it. The question goes to stderr, so testing stdin
    // alone left `hangar ssh web 2>/dev/null` blocked on a prompt nobody saw.
    //
    // Descriptor 1 is deliberately not consulted: a piped stdout is no reason
    // not to ask. That independence lives on this line and nowhere else, and it
    // is not assertable from the suite, which cannot reach this target. A test
    // that appeared to cover it could only restate what standardError() already
    // does, so there is not one.
    let canAsk = isatty(0) == 1 && Terminal.standardError().isInteractive
    let chosen: SearchEntry

    switch ConnectDecision.decide(matches: matched.count, takeFirst: command.first,
                                  canAsk: canAsk) {
    case .none:
        exit(1)                                   // already reported above
    case .connect(let index):
        chosen = matched[index]
    case .ask:
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
    case .tooMany(let hosts):
        // A script or an agent has to be specific, or say so with --first,
        // rather than have a host picked for it.
        stderrLine("hangar: \(hosts) hosts match \"\(command.searchText)\". "
                   + "Narrow it, or use --first.")
        FileHandle.standardError.write(
            Data(FleetOutput.numbered(matched, terminal: .plain).utf8))
        exit(3)
    }

    // The bare alias, which is what the listing's own `command` field has always
    // advertised: ssh_config already carries the user, the key and the ProxyJump.
    let vector = SSHCommand.arguments(target: chosen.alias, user: nil,
                                      identityFile: nil, managedByConfig: true)
    if command.dryRun {
        write(SSHCommand.line(target: chosen.alias, user: nil,
                              identityFile: nil, managedByConfig: true) + "\n")
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
