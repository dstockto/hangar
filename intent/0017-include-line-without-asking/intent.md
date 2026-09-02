# 0017: stop asking about the Include line

## How this came about

> why are we not adding aliases automatically ? why do I have to click Add
> include line ? just do it

The setup screen said "SSH aliases not active yet" with a button, on a machine
where **Write SSH config aliases** was already checked and 223 aliases had
already been written. The user had consented to the feature and still had to
press a second button to make it do anything.

## Why it was ever a click

`~/.ssh/config.d/hangar` is Hangar's file; it is rewritten on every sync and
nobody else has a claim on it. `~/.ssh/config` is the user's, hand-maintained,
and the `Include` has to go at the very top because ssh_config is
first-match-wins per keyword and a `Host *` block above it would beat every entry
Hangar generates. Editing someone's ssh config, at the top, unasked, deserved a
pause.

That reasoning is still true about *editing the file*. It was wrong about *when
to ask*, because the question was already answered: the checkbox is the consent.
Writing aliases that no terminal can see is not a feature with an optional
extra step, it is a feature that does not work yet.

## The decision

When Hangar syncs aliases and the `Include` line is absent, it adds it. Same
mechanics as the button, which are not being loosened: the file is copied to
`config.hangar-backup` first, the line goes in at the top, the result is `0600`,
and the write is skipped when the line is already there.

`manage_ssh_include` in `~/.hangar/config.json`, default true, turns it off for
anyone who includes the file their own way. Without that flag, a line deleted on
purpose would come back on the next refresh, which is its own kind of rude.

The button stays. It is the remedy when the flag is off, or when the write
failed, and the setup row that offers it now only appears in those cases.

## Out of scope

Anything else in `~/.ssh/config`. Hangar adds one line, removes that same line
on uninstall, and reads the file to see whether the line is there. It has never
had an opinion about the rest of it and still does not.
