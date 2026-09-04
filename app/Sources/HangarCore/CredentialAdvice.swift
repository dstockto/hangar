import Foundation

/// What to tell the user when credentials do not work.
///
/// The recovery depends entirely on where the credentials were supposed to come
/// from. "Run aws sso login" is the right answer for an SSO profile and useless
/// noise for someone with a key pair in ~/.aws/credentials, so the advice is
/// derived from the profile that was actually attempted rather than from the
/// word "expired" appearing somewhere in an error string.
public enum CredentialAdvice {
    public struct Advice: Sendable, Equatable {
        /// One sentence for the menu or the setup check.
        public var message: String
        /// A command worth offering to copy, when one would actually help.
        public var command: String?

        public init(message: String, command: String? = nil) {
            self.message = message
            self.command = command
        }
    }

    /// True when the failure looks like a credential lifetime problem rather than
    /// a wrong key, a missing profile, or the network being down.
    static func looksExpired(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("expired")
            || lowered.contains("expiredtoken")
            || lowered.contains("token has expired")
            || lowered.contains("session expired")
    }

    static func looksRejected(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("invalidclienttokenid")
            || lowered.contains("signaturedoesnotmatch")
            || lowered.contains("unrecognizedclient")
            || lowered.contains("accessdenied")
            || lowered.contains("unauthorized")
            || lowered.contains("not authorized")
    }

    /// `alternatives` are the other profiles that do carry credentials. Without
    /// them the only advice for a profile with nothing in it is a list of what a
    /// profile needs, which is useless to someone who already has a working
    /// profile a menu away.
    public static func forFailure(_ error: Error, profile: AWSProfile?,
                                  alternatives: [String] = []) -> Advice {
        let text = error.localizedDescription

        // An SSO error is unambiguous whatever the profile looks like.
        if let hangar = error as? HangarError {
            switch hangar {
            case .ssoTokenExpired, .noSSOToken:
                return ssoAdvice(profile: profile, text: text)
            case .noCredentials(let name):
                return noCredentialsAdvice(name: name, alternatives: alternatives)
            case .noProfile:
                return Advice(message: text)
            default:
                break
            }
        }

        guard let profile else {
            return Advice(message: text)
        }

        if profile.isSSO {
            return looksExpired(text) || looksRejected(text)
                ? ssoAdvice(profile: profile, text: text)
                : Advice(message: text)
        }

        if profile.assumesRole {
            let role = profile.roleArn ?? "the configured role"
            let source = profile.sourceProfile ?? "default"
            if looksExpired(text) {
                return Advice(
                    message: "Credentials for source profile \(source) have expired, so "
                        + "Hangar could not assume \(role). Refresh \(source), then retry.")
            }
            if looksRejected(text) {
                return Advice(
                    message: "AWS refused to assume \(role) with source profile "
                        + "\(source). Check the role's trust policy and your permissions.")
            }
            return Advice(message: text)
        }

        if profile.credentialProcess != nil {
            return Advice(
                message: "credential_process in profile \(profile.name) did not return "
                    + "credentials AWS accepted. Run it by hand to see what it returns.")
        }

        if profile.hasStaticKeys {
            // Static keys do not expire. A session token alongside them does.
            if looksExpired(text) {
                return profile.sessionToken != nil
                    ? Advice(message: "The session token in profile \(profile.name) has "
                             + "expired. Refresh it in ~/.aws/credentials, then retry.")
                    : Advice(message: "AWS reported an expired credential for profile "
                             + "\(profile.name). Check aws_session_token in "
                             + "~/.aws/credentials.")
            }
            if looksRejected(text) {
                return Advice(
                    message: "AWS rejected the access key in profile \(profile.name). "
                        + "Check the key pair in ~/.aws/credentials.")
            }
            return Advice(message: text)
        }

        return Advice(message: text)
    }

    /// A profile with nothing usable in it. Names the profiles that would work
    /// when there are any, because on a machine with three profiles the answer is
    /// to pick one rather than to go and write credentials into this one.
    private static func noCredentialsAdvice(name: String, alternatives: [String]) -> Advice {
        let others = alternatives.filter { $0 != name }
        guard !others.isEmpty else {
            return Advice(
                message: "Profile \(name) has no credentials Hangar can use. It needs a "
                    + "key pair, SSO settings, role_arn with source_profile, or "
                    + "credential_process.")
        }
        let listed = others.prefix(3).joined(separator: ", ")
        let more = others.count > 3 ? ", and \(others.count - 3) more" : ""
        return Advice(
            message: "Profile \(name) has no credentials Hangar can use. Pick one that "
                + "does: \(listed)\(more).")
    }

    /// The environment-variable case, which has no profile behind it.
    public static func forEnvironmentFailure(_ error: Error) -> Advice {
        let text = error.localizedDescription
        guard looksExpired(text) || looksRejected(text) else { return Advice(message: text) }
        return Advice(
            message: "The AWS credentials in your environment were rejected. Re-export "
                + "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN.")
    }

    private static func ssoAdvice(profile: AWSProfile?, text: String) -> Advice {
        let command = profile.map { "aws sso login --profile \($0.name)" } ?? "aws sso login"
        return Advice(
            message: "Your SSO session has expired. Run \(command), then retry.",
            command: command)
    }
}
