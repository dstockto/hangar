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

    public var query: [String] = []
    public var format: Format = .columns
    public var limit: Int?
    public var filters: [HostFilter] = []
    public var cache: String?
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
            case "--cache":
                if let text = value(argument) { command.cache = text }
            case "-h", "--help":
                command.help = true
            case "-V", "--version":
                command.version = true
            default:
                // A stray flag is a mistake worth reporting. Anything else is part
                // of the query, so `hangar web prod` works without -s.
                if argument.hasPrefix("-") && argument != "-" {
                    command.problem = "unknown option '\(argument)'"
                } else {
                    command.query.append(argument)
                }
            }
        }
        return command
    }

    /// The query as one string, which is what `Fuzzy.Query` takes.
    public var searchText: String {
        query.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
