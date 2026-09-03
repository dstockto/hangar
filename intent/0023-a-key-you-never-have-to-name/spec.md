# 0023 spec: key sources

## The core: `KeySource`

UI-free, in `HangarCore`, fully tested. Detection and emission are separate so
the emission half can be tested without an agent on the machine.

```swift
public struct AgentKey: Sendable, Equatable, Codable {
    public var algorithm: String    // "ssh-ed25519"
    public var blob: String         // base64, no whitespace
    public var comment: String      // the vault item title, may be empty
    public var publicKeyLine: String
    public var slug: String         // filename-safe, derived from comment or blob
}

public struct SSHAgent: Sendable, Equatable {
    public enum Kind: String, Sendable { case onePassword, secretive, environment }
    public var kind: Kind
    public var name: String         // "1Password", "Secretive", "your ssh agent"
    public var socket: String
    public var keys: [AgentKey]
    public var reachable: Bool      // socket answered
    public var problem: String?     // "locked", "no keys", a timeout
}
```

### Detection

`KeySource.detectAgents()` looks at three known places, in this order:

| Kind | Socket |
|---|---|
| `onePassword` | `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` |
| `secretive` | `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh` |
| `environment` | `$SSH_AUTH_SOCK`, only when it is neither of the above |

A socket that does not exist produces no entry at all. A socket that exists is
listed with `ssh-add -L` under `SSH_AUTH_SOCK`, with a 5 second deadline and a
kill. Exit status 1 with no output means the agent has no keys, which for
1Password means locked; that is reported as a problem, not as an empty list.

`KeySource.detectKeyFiles()` returns the private key names ssh itself tries, in
ssh's own order, that exist in `~/.ssh`: `id_ed25519`, `id_ecdsa_sk`,
`id_ed25519_sk`, `id_ecdsa`, `id_rsa`. Nothing is read; only the names.

### Parsing `ssh-add -L`

One key per line, `<algorithm> <base64> [comment]`. Split on the first two
spaces so a comment containing spaces survives intact. A line whose algorithm is
not `ssh-`, `ecdsa-` or `sk-` prefixed is skipped. A blob containing anything
outside base64 is skipped: it reaches an `ssh_config` file.

`slug` is the comment slugified, falling back to the last 8 characters of the
blob when the comment is empty or slugs to nothing. Two keys that slug the same
get the blob suffix appended, because the slug becomes a filename.

### Emission

`SSHSettings` gains two fields:

```swift
public var identityAgent: String?    // "identity_agent"
public var identitiesOnly: Bool?     // "identities_only"
```

`SSHConfigWriter` emits, in this order, skipping anything unset:

```
  IdentityAgent "<socket>"
  IdentityFile <path>
  IdentitiesOnly yes
```

`IdentitiesOnly` is emitted when `identities_only` is true, and when it is unset
but an `identity_file` is pinned. Setting it to false suppresses the line even
with a key pinned. That is the whole fix for the lockout: a user who wants to
name a key and still let the agent offer others now can.

The socket path goes through `SSHConfigValue.isEmittable` and `quoted` like
every other value. It contains a space on every Mac, so the quoting is load
bearing rather than defensive.

### Writing the public key

`KeySource.materialize(_ key: AgentKey) -> String` writes
`~/.hangar/keys/<slug>.pub` through `PrivateFile` and returns the path in `~`
form. Rewritten on every setup run, so a key rotated in the vault is picked up
without the user doing anything. Public keys are not secret; they get 0600
anyway because everything under `~/.hangar` does and one rule is easier to
verify than two.

## The setup screen

One card, titled **Hosts and keys**, built from detection only. It renders
nothing at all when there is nothing to say.

```
SSH key
  ✓ 1Password              2 keys      [ Prod SRE            ▾ ]
    ~/.ssh/id_ed25519      found       [ Use this key          ]
                                       [ Choose…               ]
```

Rules:

- Exactly one agent key and no explicit config: selected and written on sight,
  the popup shows it, no click needed.
- More than one: the popup lists them by item title; choosing one writes the
  config and re-syncs. Nothing is written until a choice is made.
- Agent present but unreachable or empty: the row says why, with an **Open
  1Password** button when the kind is `onePassword`.
- No agent: the key file rows appear, each with a Use button.
- Always: a **Choose…** button opening an `NSOpenPanel` at `~/.ssh`.

A `Preflight.keyCheck` reports the outcome in the same list as everything else,
so the state is visible from the menubar's setup item later, not only on first
run.

## Behaviour that must not change

- With nothing configured, Hangar still emits neither `IdentityFile` nor
  `IdentitiesOnly`, so an agent the user has already set up globally keeps
  working untouched. This is the default and it stays the default.
- No new process runs unless a socket file actually exists.
