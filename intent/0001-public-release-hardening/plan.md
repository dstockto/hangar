# Plan: public release hardening

## Order

1. `HangarCore/Sanitize.swift`, new: `SSHConfigValue`, `Shell`, `AWSRegion`,
   `HangarHTTP`. Everything else depends on it.
2. `HangarCore/SSHConfigWriter.swift`: quote through `option()`, skip unwritable
   hosts, report them in `SyncResult`.
3. `HangarCore/EC2.swift`, `Credentials.swift`, `SSO.swift`: validated endpoints,
   ephemeral session, token cache created at `0600`.
4. `Hangar/Launcher.swift`: shell-quote the target, refuse multi-line commands.
   Move the command builder to `HangarCore/SSHLogin.swift` so it is testable.
5. `Hangar/FleetStore.swift`: cache at `0600`, surface omitted hosts.
6. `Hangar/Updates.swift`: `ditto`, re-verify the staged copy, `-t exec`, and a
   swap helper that can roll back.
7. Test target replaces `hangar-selftest`; `scripts/test.sh` and `make test`.
8. Remove `bin/hangar`. Add `.github/workflows/ci.yml`, `SECURITY.md`,
   `CONTRIBUTING.md`, issue templates.

## Tests that prove it

- `SanitizeTests`: quoting, refusal, shell quoting, region validation, and a
  hostile hostname that cannot escape into the shell.
- `SSHConfigWriterTests`: a space in a hostname tag still yields a file `ssh -G`
  accepts; a newline never writes `ProxyCommand` and is reported; a bad override
  drops one option, not the host.
- Manual, and recorded here because it cannot be a unit test: re-sign a copy of
  the bundle ad hoc and confirm both updater gates reject it.

## Risk

The ssh config writer is the one component that can lock a user out of every host
they have. It is rewritten wholesale each sync and validated by `ssh` itself
before being moved into place, so a rejected file leaves the previous one intact.
