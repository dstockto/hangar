# Spec: credential advice per profile type

`CredentialAdvice.forFailure(_:profile:)` returns a message and an optional
command, derived from the profile that was attempted rather than from the error
text alone.

| Profile | Failure looks like | Message names | Command |
|---|---|---|---|
| SSO | expired or rejected | the SSO session | `aws sso login --profile <name>` |
| Static keys, with session token | expired | the session token, and `~/.aws/credentials` | none |
| Static keys | rejected | the access key and the profile | none |
| Assumed role | expired | the source profile to refresh | none |
| Assumed role | rejected | the role and its trust policy | none |
| credential_process | any | the command to run by hand | none |
| Environment | expired or rejected | the `AWS_*` variables to re-export | none |
| Any | unrelated | the error as it came | none |

An SSO-specific error type (`ssoTokenExpired`, `noSSOToken`) is trusted whatever
the profile looks like, since it can only come from the SSO path.

`Preflight.credentialsCheck` takes the advice rather than a string and a profile
name, and titles the check "Credentials expired" only when a command applies.
The menu offers "Copy Login Command" only when `advice.command` is non-nil, and
offers "Retry" always.

## Acceptance

A static-keys profile receiving an expired-token error is never told to run
`aws sso login`, and is never offered a command to copy.
