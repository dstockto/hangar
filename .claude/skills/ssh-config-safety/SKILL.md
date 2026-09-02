---
name: ssh-config-safety
description: Rules for any change that writes ~/.ssh/config.d/hangar, builds a command handed to a terminal, or interpolates a value from an EC2 tag or ~/.hangar/config.json. Use when touching SSHConfigWriter, Launcher, SSHCommand, or anything that reads instance tags.
---

# ssh_config and shell safety

The file Hangar writes is one `ssh` reads directives from, and `ProxyCommand` is
arbitrary code execution on connect. Tag values are written by anyone who can tag
the account. Treat them as attacker-controlled.

## Before writing any value into ssh_config

1. `SSHConfigValue.isEmittable(_:)` first. False for empty, and for anything
   containing a newline, carriage return, NUL, or a double quote. ssh_config
   offers no way to escape a quote inside a quoted argument, so a value carrying
   one cannot be represented and must not be guessed at.
2. `SSHConfigValue.quoted(_:)` second. Wraps in double quotes when the value
   contains whitespace. Skipping this is the bug that cost a user every alias in
   the file: EC2 permits spaces in tag values, and `HostName web 1` makes `ssh`
   reject the entire file.
3. Comment lines go through `SSHConfigValue.comment(_:)`, which flattens newlines.

Never build a directive line by string interpolation. Use
`SSHConfigWriter.option(_:_:)`, which does all three and returns nil when the
value cannot be written.

## When a value cannot be represented

Drop the smallest thing that works, and say so.

- An unusable **hostname** means the host cannot be written. Omit that host and
  report its id in `SyncResult.omittedHosts`.
- An unusable **option value** from an override means dropping that option only.
  The host still gets written.

Never drop silently. A host that vanishes from the menu looks like it was
terminated, and the user will go looking in the wrong place.

## Before handing a command to a terminal

- `Shell.quoted(_:)` on every interpolated value. Aliases Hangar generates are
  slugified and safe; a hostname tag is not.
- `Shell.isSingleLine(_:)` on the finished command. A newline both ends the
  AppleScript string literal and submits the line to the shell early.

## Process execution

Absolute executable path, arguments as an argument vector, never a string given to
a shell. `credential_process` is the sole exception, because it is the user's own
configured command, and it is documented as such in `SECURITY.md`.

## Validating the result

`SSHConfigWriter.sync` writes a temporary file, has `ssh -F <file> -G` parse it,
and only then moves it into place. Keep that order. A rejected file must leave the
previous one intact, because this is the one file that can lock a user out of
every host they have.

## Tests a change here needs

Add to `SSHConfigWriterTests` and `SanitizeTests`:

- The value shape you introduced, quoted, surviving a real `ssh -G` parse.
- A newline in that value, proving the directive is never written and the host is
  reported.
- The blast radius: one bad value must not cost a second host its entry.
