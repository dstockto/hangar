import Foundation

/// Running one command per matched host.
///
/// This is `xargs` with names instead of positions, and the reason it exists
/// rather than a documented `$(hangar -a …)` loop is the substitution: it happens
/// per argument, into an argument vector, so **no shell ever parses a tag**. A
/// command substitution in a shell re-parses whatever the tags contained, and
/// tags are written by anyone who can tag the account.
///
/// Deliberately knows nothing about terminals. Hangar already drives three of
/// them, and herdr, tmux, kitty and WezTerm would make the launcher a matrix. A
/// vector per host composes with all of them and with everything else.
public enum ExecPlan {

    /// The names a command may use, and where each comes from.
    ///
    /// Every one is a field the listing already prints, so what you can see you
    /// can substitute.
    public static func placeholders(for entry: SearchEntry) -> [String: String] {
        var values = FleetOutput.fields(entry)
        values.removeValue(forKey: "command")   // Not a value; it is another command.
        values["type"] = entry.instance.type
        values["asg"] = entry.instance.asg
        return values
    }

    /// One argument with its placeholders filled in.
    ///
    /// An unknown `{name}` is left exactly as it is. Replacing it with nothing
    /// would silently drop part of somebody's command, and a command that runs
    /// differently from how it reads is worse than one that fails.
    public static func substitute(_ argument: String,
                                  _ values: [String: String]) -> String {
        guard argument.contains("{") else { return argument }
        var result = ""
        var name: String?
        for character in argument {
            switch (character, name) {
            case ("{", nil):
                name = ""
            case ("}", .some(let key)):
                result += values[key] ?? "{\(key)}"
                name = nil
            case (_, .some(let key)):
                name = key + String(character)
            case (_, nil):
                result.append(character)
            }
        }
        // An unclosed brace is text, not a placeholder that never ended.
        if let name { result += "{" + name }
        return result
    }

    /// The vector to run for one host: the program, then its arguments with the
    /// host's values in them.
    public static func vector(_ template: [String], for entry: SearchEntry) -> [String] {
        let values = placeholders(for: entry)
        return template.map { substitute($0, values) }
    }

    /// What to do about one host: run this vector, or refuse and say why.
    public enum Planned: Equatable, Sendable {
        case run([String])
        case refuse(String)
    }

    /// The vector, unless a tag would arrive at the program as an option.
    ///
    /// Mistake 9, one layer out. An argument vector stops a value becoming a
    /// second *command*; it does not stop a value becoming a *flag*. A hostname
    /// tag of `-oProxyCommand=…` under the documented `--exec ssh {hostname}`
    /// reaches ssh as an option, and ProxyCommand is something ssh executes.
    ///
    /// This catches a value that becomes a flag, and nothing more. A value that
    /// lands in an option's *argument* position is still the program's business:
    /// `--exec ssh -o {hostname}` with a tag of `ProxyCommand=…` expands to
    /// something that does not begin with a hyphen and is not refused. Hangar
    /// cannot know an arbitrary program's option grammar, which is why the
    /// documentation says prefer `{alias}` and shows the `--` form rather than
    /// claiming this guard is a fence.
    ///
    /// Only refused when the whole argument came from a placeholder, so a
    /// template that spells its own flag (`-o{setting}`) is untouched. Refused
    /// per host and reported rather than failing the run, because one badly
    /// tagged instance should not stop the other twenty: "a host that cannot be
    /// represented is skipped and reported, never silently dropped".
    public static func plan(_ template: [String], for entry: SearchEntry) -> Planned {
        let values = placeholders(for: entry)
        var vector: [String] = []
        for argument in template {
            let filled = substitute(argument, values)
            if argument.hasPrefix("{"), filled.hasPrefix("-") {
                return .refuse("a tag expanded to '\(filled)', which "
                               + "\(template.first ?? "the command") would read as an "
                               + "option. Put -- before it, or use {alias}.")
            }
            vector.append(filled)
        }
        return .run(vector)
    }

    /// One entry per host, in the order they matched.
    public static func plans(_ template: [String],
                             for entries: [SearchEntry]) -> [Planned] {
        entries.map { plan(template, for: $0) }
    }

    /// Every vector this command would run, in the order the hosts matched.
    public static func vectors(_ template: [String],
                               for entries: [SearchEntry]) -> [[String]] {
        entries.map { vector(template, for: $0) }
    }

    /// Whether running this needs a person to say yes first.
    ///
    /// One host is what was asked for. More than one is a fan-out, and a fan-out
    /// nobody confirmed is how a command meant for a canary reaches the fleet.
    /// A caller with no terminal cannot be asked, so it has to have said `-y`
    /// already: an agent must say out loud that it meant to.
    public enum Consent: Equatable, Sendable {
        /// Run it.
        case granted
        /// Ask, showing this many hosts.
        case ask(hosts: Int)
        /// Refuse, because there is nobody to ask and nobody said yes.
        case needsExplicitYes(hosts: Int)
    }

    public static func consent(hosts: Int, alreadyGiven: Bool,
                               canAsk: Bool) -> Consent {
        if alreadyGiven || hosts <= 1 { return .granted }
        return canAsk ? .ask(hosts: hosts) : .needsExplicitYes(hosts: hosts)
    }

    /// A yes is a yes typed out. Anything else, including a bare Return, is not.
    public static func agrees(_ input: String?) -> Bool {
        let answer = input?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// A vector as a line to read, never to run. Quoted so a reader can see where
    /// each argument begins and ends, which matters most when a tag put a space
    /// or a semicolon in one.
    public static func readable(_ vector: [String]) -> String {
        vector.map { argument in
            argument.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber
                    || "-_./:=@+,".contains($0))
            } && !argument.isEmpty ? argument : Shell.quoted(argument)
        }.joined(separator: " ")
    }
}
