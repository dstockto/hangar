# Review policy

What every change is reviewed against, before merge. Each pass is a separate
question; a change can pass one and fail another. An agent may run these passes
and report findings, and an agent may not approve its own work: the merge decision
is a person's.

Run with `/code-review` locally, or as the review job on the pull request.

## Pass 1: Correctness

- Does the change do what its `intent.md` said, and only that?
- Is there a test that fails without the change? A behaviour change without one
  is not finished.
- `make test` green, and the release build warning-free in Swift 6 mode.
- Are the unhappy paths covered: network failure, expired credentials, a malformed
  config, an empty fleet, a fleet whose tags Hangar does not recognise?
- Does anything force-unwrap a value derived from configuration or from AWS?

## Pass 2: Security

The threat model is small and specific. Hangar reads the user's AWS credentials
and writes a file that `ssh` executes directives from.

- **Untrusted input.** Does any new value from an EC2 tag or from
  `~/.hangar/config.json` reach `ssh_config`, a shell command, a `Process`
  argument, or a URL without passing through `SSHConfigValue`, `Shell` or
  `AWSRegion`?
- **Injection.** Could a tag value append an `ssh_config` directive, or a second
  shell command? `ProxyCommand` is arbitrary code execution on connect.
- **Credentials.** Are they kept out of logs, out of error strings shown to the
  user, and off any shared URL cache? Credential calls use `HangarHTTP.session`,
  which is ephemeral by construction.
- **File modes.** Anything new under `~/.hangar` is `0600`. Is the mode set
  without a window where the file exists more permissively?
- **Process execution.** Absolute paths, arguments as an argument vector, never a
  string handed to a shell. The one exception is `credential_process`, which is
  the user's own configured command and is documented as such.
- **The updater.** Both gates still enforced: `spctl -a -t exec` and the pinned
  `certificate leaf[subject.OU]` requirement, on the mounted image *and* on the
  staged copy.
- **Secrets in the diff.** No keys, tokens, real hostnames, internal addresses or
  customer data. Fixtures use documented placeholder values.

## Pass 3: Privacy and claims

Hangar's pitch is that nothing leaves the machine. That is a claim the code has to
keep earning.

- Does the change add a network call? To where, triggered by what, and is it
  disclosed in the README and `SECURITY.md`?
- Does it write anything outside `~/.hangar` and `~/.ssh/config.d/hangar`?
- Does any user-facing copy or landing-page claim become untrue? The site states
  no server, no account, no telemetry, read-only against AWS.
- Does anything new get logged that would embarrass a user reading their own logs?

## Pass 4: Interface and brand

- Does new UI copy match the voice: direct, concrete, no marketing language?
- No em dashes. No `text-transform` applied to a product name.
- Colour never carries state alone: a glyph or a word says it too.
- Are the brand assets used as supplied, not redrawn?
- Accessibility: labels on controls, keyboard operation, contrast, and a decorative
  demo not exposed to a screen reader as functional UI.

## Pass 5: Maintenance

- Is anything now dead? Unused enum cases, unreferenced functions, a code path the
  documentation describes but nothing calls.
- Does the documentation still match: `README.md`, `SECURITY.md`, `CLAUDE.md`?
- Is a new mistake worth recording in the "Mistakes this repo has already made"
  section of `CLAUDE.md`?

## Blocking versus advisory

**Blocking:** a failing test, a Swift 6 warning, an untrusted value reaching
`ssh_config` or a shell unsanitized, a secret in the diff, a false claim in
user-facing copy, a documented feature that is not wired.

**Advisory:** naming, structure, comment density, anything stylistic. Say it once
and move on.
