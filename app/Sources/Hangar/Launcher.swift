import AppKit
import HangarCore

/// Opens ssh sessions in the user's terminal. Once the ssh_config include is in
/// place every host is reachable by alias, so the command is just `ssh <alias>`
/// and the terminal inherits user, key, and ProxyJump from ssh itself.
enum Launcher {
    enum Terminal: String {
        case iterm, terminal

        static func from(_ raw: String?) -> Terminal {
            switch (raw ?? "iterm").lowercased() {
            case "terminal", "terminal.app", "apple": return .terminal
            default: return .iterm
            }
        }

        var bundleID: String {
            switch self {
            case .iterm:    return "com.googlecode.iterm2"
            case .terminal: return "com.apple.Terminal"
            }
        }

        var isInstalled: Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    static func sshCommand(for target: String, settings: HangarConfig.SSHSettings?,
                           managedByConfig: Bool) -> String {
        SSHCommand.line(target: target, user: settings?.user,
                        identityFile: settings?.identityFile,
                        managedByConfig: managedByConfig)
    }

    @discardableResult
    static func open(command: String, in terminal: Terminal) -> String? {
        // A newline here would end the AppleScript string literal and, worse,
        // submit the line to the shell early. Nothing legitimate contains one.
        guard Shell.isSingleLine(command) else {
            return "That host's tags contain a line break; Hangar will not run it."
        }
        let target = terminal.isInstalled ? terminal : .terminal
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Write the command into a live session rather than passing it as the
        // session's command. If it is passed as the command, a failing ssh exits
        // immediately and iTerm closes the tab, so the user sees an empty window
        // and never learns why. A shell that outlives ssh shows the error.
        let script: String
        switch target {
        case .iterm:
            script = """
            tell application "iTerm"
              activate
              if (count of windows) is 0 then
                create window with default profile
              else
                tell current window to create tab with default profile
              end if
              tell current session of current window
                write text "\(escaped)"
              end tell
            end tell
            """
        case .terminal:
            script = """
            tell application "Terminal"
              activate
              do script "\(escaped)"
            end tell
            """
        }

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return "Hangar needs permission to control \(target == .iterm ? "iTerm" : "Terminal"). "
                    + "Allow it in System Settings under Privacy and Security, Automation."
            }
            return error[NSAppleScript.errorMessage] as? String ?? "could not open a terminal"
        }
        return nil
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
