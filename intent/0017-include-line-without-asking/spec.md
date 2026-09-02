# 0017 spec: the Include line looks after itself

## Where the decision lives

`SSHConfigWriter.sync` gains `ensuringInclude: Bool` and an `includePath`, so
the whole behaviour is in the core and testable against temporary files rather
than someone's real `~/.ssh/config`.

```swift
public func sync(instances: [Instance], region: String,
                 to path: String = HangarConfig.sshIncludePath,
                 ensuringInclude: Bool = false,
                 includePath: String = defaultUserConfigPath) throws -> SyncResult
```

Order inside `sync` is unchanged and then extended: render, validate with `ssh`
itself, move into place, chmod, and only then consider the `Include`. A sync that
fails never touches `~/.ssh/config`; there would be nothing worth including.

`SyncResult` reports what happened rather than what is needed:

| Field | Meaning |
|---|---|
| `includeLineNeeded` | the line is absent and Hangar did not add it |
| `includeLineAdded` | Hangar added it during this sync |

## When it runs

`FleetStore.syncSSHConfig` passes `ensuringInclude: config.manageSSHInclude`,
which defaults to true. Alias writing is already gated on
`sync_ssh_config_on_refresh`, so an unchecked **Write SSH config aliases** means
nothing is written anywhere, including the `Include`.

## What the user sees

- Nothing, when it works. `lastSyncMessage` stays "SSH config updated" and the
  setup row reads "SSH aliases active".
- The **Add Include Line** remedy only when the line is absent *and* Hangar is
  not managing it, or the automatic write failed. A button offering to do
  something that already happened is noise.
- One log line, `ssh include line added to ~/.ssh/config`, because a file in the
  user's home changed and the log is where that is recorded.

## Failure

An `Include` write that throws does not fail the sync: the aliases are written
and usable through Hangar itself. The message says the line could not be added,
the remedy button comes back, and the log carries the reason.

## Tests

Against temporary files, in the core:

- Sync with `ensuringInclude: true` on a config with no include adds exactly one
  line, at the top, and reports `includeLineAdded`.
- Sync with `ensuringInclude: true` on a config that already has it changes the
  file not at all, byte for byte.
- Sync with `ensuringInclude: false` leaves the file alone and reports
  `includeLineNeeded`.
- The line lands above a pre-existing `Host *` block.
- The user's own content survives, including a config that did not end in a
  newline.
- The edited file is `0600`, and a backup exists.
