# 0023: a key you never have to name

## How this came about

> if people are using 1password for their ssh key, how can we integrate that
> seamlessly ? I have 1password, and CLI, I can move my key there and we can
> figure this workflow and get that hooked in.
>
> maybe give predifined paths on setup screen to setup hosts + key ?
>
> I want this to work as smoothly as imaginable .... no cluncky setup at all
>
> "it should just work" is always my motto

## What was actually true

Hangar was already 90% compatible with 1Password and did not know it.

1Password's app writes `Host * / IdentityAgent ~/Library/Group
Containers/2BUA8C4S2C.com.1password/t/agent.sock` into `~/.ssh/config`. Hangar's
Include sits above that block, `ssh_config` is first-value-wins per keyword, and
Hangar's generated blocks never set `IdentityAgent`. So the agent already applied
to every Hangar alias, by accident rather than by design.

What broke it was Hangar's own code. `SSHConfigWriter` emitted `IdentitiesOnly
yes` whenever `identity_file` was set, and `IdentitiesOnly yes` tells ssh to
ignore every key an agent offers unless it matches a listed `IdentityFile`. A
1Password user who filled in the key field on the setup screen locked themselves
out of their own vault, silently, on every host at once. That is mistake 2 in a
new place: a setting that is correct for one credential type and wrong for
another, with no way for the user to tell which one they have.

The second thing that was true: the setup screen has a field that invites the
wrong answer. Asking someone for a key path assumes the key is a path. For a
vault user, a hardware key user, or anyone on an agent, it is not.

## What was decided

**A key source, not a key path.** The unit of configuration becomes where the
key lives, and there are three kinds: an agent socket, a file, or nothing at all
(let ssh decide, which is what Hangar already did well). 1Password is the first
implementation of the agent kind, not a special case. Secretive and a plain
`$SSH_AUTH_SOCK` fall out of the same code with no extra work.

**No `op` CLI dependency.** The agent lists its own keys:

```sh
SSH_AUTH_SOCK=<socket> ssh-add -L
```

returns every public key it holds, with the vault item title as the comment.
That is the whole discovery mechanism. No `op` on `PATH`, no vault read, no
private key ever touching disk, and the same "no runtime dependency on a vendor
CLI" property the AWS side already has.

**Narrow the agent to one key.** When a key is chosen, Hangar writes its public
key under `~/.hangar/keys` and emits three lines instead of two:

```
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  IdentityFile ~/.hangar/keys/prod-sre.pub
  IdentitiesOnly yes
```

Pointing `IdentityFile` at the public key is the documented way to tell ssh
which agent key to offer. It is not cosmetic: a vault holding a dozen keys blows
past `MaxAuthTries` and the user gets "Too many authentication failures" on a
host that would otherwise work. Hangar writing the right public key per host is
strictly better than the global config 1Password sets up for itself.

**The setup screen reports, it does not ask.** No path fields. One card that
says what was found, with the answer already chosen when there is only one:

- socket missing: nothing shown, no clutter
- one key: use it, no question asked
- several keys: listed by item title, one click
- socket present, zero keys: "1Password is locked", with an Unlock button

The one escape hatch is a Choose button behind an `NSOpenPanel`, for the case
the detection cannot cover.

**A deadline on `ssh-add`.** Mistake 20 said every process Hangar runs gets a
deadline and a kill, and a locked vault is exactly the shape that hangs. The
deadline logic was inline in `CredentialResolver`; it moves to `ProcessRunner`
so both callers share one implementation rather than two that drift.

## What this does not do

It does not read, export, or store a private key, and it does not talk to
1Password over anything but the agent socket ssh itself would use. If that is
ever not enough for a feature, the feature is wrong.
