import Foundation

/// The `hangar` command line, parsed.
///
/// Here rather than beside `main.swift` for the reason `SSHCommand` is here: an
/// executable target is not reachable from the suite, and an argument parser
/// nobody can test is exactly where the next flag goes wrong.
public struct HangarCommand: Equatable, Sendable {
    public enum Format: String, Equatable, Sendable {
        case columns, alias, tsv, json
    }

    /// What was asked for. A verb is the first plain word on the line, so
    /// `hangar --json tags` still works and `hangar web tags` is still a search
    /// for two words. `-s` and `--` are the escapes a fleet with a host named
    /// after a verb needs, and both already meant what they mean here.
    public enum Verb: Equatable, Sendable {
        /// Print matching hosts. The default, and what every version so far did.
        case list
        /// Print the tag keys this fleet uses.
        case tags
        /// Print the values one tag key takes. Takes the key as its argument.
        case values
        /// Connect to the one matching host.
        case ssh
    }

    /// The word, when it is one. Deliberately not `RawRepresentable`: `list` is
    /// the default rather than something to type, and a host named "list" must
    /// keep being findable.
    static func verb(for word: String) -> Verb? {
        switch word {
        case "ssh":    return .ssh
        case "tags":   return .tags
        case "values": return .values
        default:       return nil
        }
    }

    public var verb: Verb = .list
    public var query: [String] = []
    public var format: Format = .columns
    public var limit: Int?
    public var filters: [HostFilter] = []
    public var cache: String?
    /// Take the best match without asking. What `| head -1` meant, said out loud.
    public var first = false
    /// Print what would have been run, and run nothing.
    public var dryRun = false
    /// The program and arguments to run once per matched host. Empty means none.
    public var exec: [String] = []
    /// How many of those may run at once.
    public var parallel = 1
    /// How long each one gets, or nothing, which is the default.
    public var timeout: Double?
    /// Consent to a fan-out, given in advance.
    public var yes = false
    public var help = false
    public var version = false
    /// What is wrong with the command line, kept rather than thrown so parsing
    /// finishes and `--help` still answers on a line that also has a typo.
    public var problem: String?

    public init() {}

    /// Reads the whole line and never throws: what is wrong lands in `problem`
    /// and parsing continues, so `--help` still answers on a line that also has
    /// a typo, and the caller decides what a bad command line costs.
    public static func parse(_ arguments: [String]) -> HangarCommand {
        var command = HangarCommand()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            func value(_ flag: String) -> String? {
                guard index < arguments.endIndex else {
                    command.problem = "\(flag) needs a value"
                    return nil
                }
                defer { index += 1 }
                return arguments[index]
            }
            switch argument {
            case "-s", "--search":
                if let text = value(argument) { command.query.append(text) }
            case "-a", "--alias", "--aliases":
                command.format = .alias
            case "--tsv":
                command.format = .tsv
            case "--json":
                command.format = .json
            case "-l", "--list":
                break   // The list is an empty query, so this is the default already.
            case "-n", "--limit":
                guard let text = value(argument) else { break }
                guard let count = Int(text), count > 0 else {
                    command.problem = "--limit needs a positive number, not '\(text)'"
                    break
                }
                command.limit = count
            case "-f", "--filter":
                guard let text = value(argument) else { break }
                switch HostFilter.parse(text) {
                case .filter(let filter): command.filters.append(filter)
                case .problem(let problem): command.problem = problem
                }
            case "--exec":
                // Everything after this belongs to the program being run, flags
                // included, so it is taken whole rather than parsed.
                guard index < arguments.endIndex else {
                    command.problem = "--exec needs a program to run"
                    break
                }
                command.exec = Array(arguments[index...])
                index = arguments.endIndex
            case "--parallel":
                guard let text = value(argument) else { break }
                guard let count = Int(text), count > 0 else {
                    command.problem = "--parallel needs a positive number, not '\(text)'"
                    break
                }
                command.parallel = count
            case "--timeout":
                guard let text = value(argument) else { break }
                guard let seconds = Double(text), seconds > 0 else {
                    command.problem =
                        "--timeout needs a positive number of seconds, not '\(text)'"
                    break
                }
                command.timeout = seconds
            case "-y", "--yes":
                command.yes = true
            case "-1", "--first":
                command.first = true
            case "--dry-run":
                command.dryRun = true
            case "--cache":
                if let text = value(argument) { command.cache = text }
            case "--":
                // Everything after this is a query: never an option, never a
                // verb. The way to search for a host called "tags".
                while index < arguments.endIndex {
                    command.query.append(arguments[index])
                    index += 1
                }
            case "-h", "--help":
                command.help = true
            case "-V", "--version":
                command.version = true
            default:
                // A stray flag is a mistake worth reporting. Anything else is part
                // of the query, so `hangar web prod` works without -s.
                if argument.hasPrefix("-") && argument != "-" {
                    command.problem = "unknown option '\(argument)'"
                } else if command.verb == .list, command.query.isEmpty,
                          let named = verb(for: argument) {
                    // The first plain word, and only that one. A value that
                    // arrived through -s never reaches here, and neither does
                    // anything after --, which is what makes both of them escapes.
                    command.verb = named
                } else {
                    command.query.append(argument)
                }
            }
        }
        if command.problem == nil, !command.help, !command.version {
            command.problem = command.argumentProblem
        }
        return command
    }

    /// What a verb needs and did not get. Checked after the whole line is read,
    /// so the order of the arguments does not decide whether it is reported.
    private var argumentProblem: String? {
        // Flags that narrow a listing mean nothing to a command that counts the
        // whole fleet, and taking them silently is how somebody believes they
        // asked a narrower question than they did.
        if verb == .tags || verb == .values {
            if !filters.isEmpty {
                return "-f narrows a listing; 'hangar \(verbName)' counts the whole fleet"
            }
            if limit != nil {
                return "-n limits a listing; 'hangar \(verbName)' counts the whole fleet"
            }
        }
        if !exec.isEmpty, verb != .list {
            return "--exec runs a command over a listing, not over 'hangar \(verbName)'"
        }
        // --first picks one host to connect to. Under --exec it did nothing at
        // all, so a caller reading it as "just the first one" fanned out.
        if !exec.isEmpty, first {
            return "--first picks one host for ssh; --exec runs on all that matched"
        }
        switch verb {
        case .list:
            return nil
        case .ssh:
            // Without either, every host matches and --first opens a session on
            // whatever sorts first. "The best match" needs a match.
            return query.isEmpty && filters.isEmpty
                ? "ssh needs a query or a filter, as in 'hangar ssh web prod'"
                : nil
        case .tags:
            return query.isEmpty ? nil
                : "tags takes no arguments; did you mean 'hangar values \(query[0])'?"
        case .values:
            if query.isEmpty {
                return "values needs a tag key, as in 'hangar values env'"
            }
            if query.count > 1 {
                return "values takes one tag key, not \(query.count)"
            }
            return nil
        }
    }

    /// The verb as it was typed, for a message about it.
    private var verbName: String {
        switch verb {
        case .list:   return "list"
        case .tags:   return "tags"
        case .values: return "values"
        case .ssh:    return "ssh"
        }
    }

    /// The tag key `values` was asked about.
    public var valuesKey: String? { verb == .values ? query.first : nil }

    /// The query as one string, which is what `Fuzzy.Query` takes.
    public var searchText: String {
        query.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
