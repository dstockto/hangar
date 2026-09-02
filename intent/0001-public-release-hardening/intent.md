# 0001: what breaks when a stranger runs this

## How this came about

The repository was about to go public, and the question was put plainly: *sweep
the codebase and tell me what needs addressing before this is for public
consumption.* Followed by: *make it as optimal and as secure as possible.*

That reframes the work. Code that is fine for one operator who knows its habits
is not automatically fine for a stranger pointing it at their own AWS account,
and a public repository invites people to read it for holes rather than use it.
So the sweep asked, of every component: what does this do with input it did not
choose, and what does it claim that is not true?

## What the questions turned up

**What does the ssh config writer do with a value it did not choose?** It
interpolated it. EC2 permits spaces in tag values, and an unquoted
`HostName web 1` makes `ssh` reject the entire file, so one sloppy tag anywhere
in the account cost the user all 249 of their aliases. Reproduced with
`ssh -F <file> -G`, which answers `keyword hostname extra arguments at end of
line` and exits 255.

**What happens on a plausible typo?** `URL(string: "https://ec2.\(region)…")!`
traps. A region of `us west 2` in a hand-edited config crashes the app on
refresh. Four call sites had the same shape.

**Does the documentation describe code that runs?** Not entirely. The verified
in-place updater was complete, careful, and called by nothing, while the README,
`SECURITY.md` and `RELEASING.md` all explained how it verified downloads.

**Is `bin/hangar` shipping?** It advertised a `--sync` flag it never implemented,
pointed at config paths the app does not use, and needed `aws` and `jq`, which
contradicted the README's claim of no runtime dependencies. It was the single
biggest "this is unfinished" signal in the tree.

**Are the files we write as private as we say?** The fleet cache was 0644 while
everything else was 0600, and it holds the whole inventory: instance ids, private
addresses, every tag.

## What was decided

Sanitize at the boundary rather than at each call site: `SSHConfigValue`, `Shell`
and `AWSRegion` in one file, so there is one place to look and one place to add
to. A value that cannot be represented is dropped and **reported**, because a
host that silently vanishes from the menu looks terminated and sends the user
looking in the wrong place.

Delete `bin/hangar` rather than fix it. Wire the updater rather than delete it,
tracked separately as 0005.

## What was not done

Feature work and visual design. Both came later, and mixing them into a security
pass would have made the diff unreviewable.

## Proof

`SanitizeTests` and `SSHConfigWriterTests`, including a spacey tag that produces
a file `ssh -G` accepts and a newline that never writes `ProxyCommand`. The
updater's two gates were checked by hand against an ad-hoc re-signed bundle:
`spctl` rejected it and the pinned team requirement failed, as intended.
