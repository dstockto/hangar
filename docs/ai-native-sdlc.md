# How this repository is built

Hangar is written by a person working with an agent, and the repository is laid
out so that arrangement produces something trustworthy rather than something that
merely compiles. This is a description of the actual working method, adapted from
[the AI-native SDLC playbook](https://claude.com/blog/the-ai-native-sdlc-playbook),
plus an honest account of where the method came from and where it has already
paid for itself.

## The problem the structure solves

An agent can write a great deal of plausible code very quickly. Plausible is the
dangerous word. Hangar reads the user's AWS credentials and writes a file that
`ssh` executes directives from, so "it built and the tests passed" is not the same
as "this is safe to run against someone's production fleet".

Speed is not the constraint. Judgment is. So the repository is arranged to put
human judgment at the points where being wrong is expensive, and to get out of
the way everywhere else.

## The stages

Each stage produces an artifact that is cheap to disagree with, in
`intent/<n>-<slug>/`.

| Stage | Artifact | The question it answers |
|---|---|---|
| Plan | `intent.md` | What problem, for whom, under what constraints, and what is explicitly out of scope |
| Design | `spec.md` | What the behaviour will be, precisely enough that a reader can object |
| Build | `plan.md` | Which files change, in what order, and which tests prove it |
| Test | the suite | Does it do what the spec said, including on the unhappy paths |
| Review | `REVIEW.md` | Correctness, security, privacy, interface, maintenance, as separate passes |
| Maintain | `evals/` | Are the product's promises still true after the next refactor |

The reason for writing intent before code is not ceremony. It is that a paragraph
is cheap to throw away and a merged branch is not. The most valuable thing in
`intent/0003-tag-mapping/intent.md` is a single question that was asked out loud:
*if someone downloads this for their own fleet, does it work?* The answer was no,
for most fleets, and finding that out cost one sentence.

Not everything needs three files. A one-line fix needs a commit message. The
threshold is roughly: if it changes behaviour a user could notice, or it touches
credentials, `ssh_config`, or the updater, it gets an `intent.md`.

## What the agent knows without being told

- **`CLAUDE.md`** is the institutional memory: commands, architecture, the rules
  about untrusted input, and a list of mistakes this repository has already made.
  That last section is the highest-value part of the file. Every entry cost real
  debugging, and each one is a mistake an agent would otherwise cheerfully make
  again, because each was locally reasonable.
- **`.claude/skills/`** holds the procedures that are too detailed for `CLAUDE.md`
  and too important to improvise: how to write a value into `ssh_config` safely,
  how to cut a release. They load when the work touches that area.
- **`.claude/agents/`** holds reviewers with narrow mandates. The security
  reviewer does not comment on naming; that is somebody else's pass.

## Where the human stays

The gates are deliberately few, and they are all in one place,
`.claude/hooks/production-gate.sh`:

- Force-pushing over published history.
- Deleting a published release, which breaks the in-app updater for anyone on it.
- Changing repository visibility, which is a one-way door.
- Notarizing, because it submits the binary to Apple.
- Reading `~/.aws/credentials` or an SSH private key, which would put credential
  material into a transcript.

Everything else, including writing the code and running the tests, does not need
a person in the loop. The gate is advisory rather than a security boundary; it
catches the mistake of the moment, which is what most mistakes are.

An agent may run every review pass in `REVIEW.md` and may not approve its own
work. That distinction is the whole point of the arrangement.

## Evals versus tests

The unit tests in `app/Tests` prove the implementation works. The eval cases in
`evals/` assert the product's promises, which are a different thing:

- No AWS call uses a URL session with a shared on-disk cache.
- No endpoint URL is built by force-unwrapping an interpolated string.
- A fleet tagged `Service`/`Environment`/`Component` works with no configuration.
- A static-keys user is never told to run `aws sso login`.
- The in-place updater the documentation describes is actually called.
- The landing page loads nothing from another origin.

Every one of those exists because it was once false. That is the admission
criterion: a case that has never been able to fail is decoration. Each is checked
by a command whose exit status is the verdict, so a promise cannot rot into a
comment nobody reads.

## What this actually caught

The method is worth the words only if it finds things. From the first pass over
this repository, before it went public:

- **One bad tag took out every alias.** EC2 permits spaces in tag values, and an
  unquoted `HostName web 1` made `ssh` reject the entire generated file, so a
  single sloppy tag anywhere in the account cost the user all 249 aliases. Found
  by asking what the writer does with a value it did not choose.
- **Hardcoded tag names made the app useless to anyone else.** Found by asking
  who the user is, which is a question `intent.md` forces.
- **Advice that was wrong for most users.** "Run `aws sso login`" was shown for
  any error containing "expired", which is useless to someone with a key pair.
  Found by looking at a screenshot of the menu and asking what a different kind
  of user would see.
- **Dead code that three documents described as shipping.** The verified in-place
  updater existed and nothing called it. Found by the maintenance pass asking
  whether the documentation still matches the code.
- **A crash from a plausible typo.** `URL(string: "https://ec2.\(region)…")!`
  traps on a region containing a space.
- **`rm -rf` before the replacement succeeded**, in the update helper.
- **A landing page that was never being served at all**, while Jekyll rendered
  the README and leaked raw Markdown into the hero. Found by capturing the
  production site before changing anything, which the build stage requires.

None of those were found by the compiler, and only two would have been found by
running the app the way its author runs it.

## Honesty about the backfill

`intent/0001` through `0006` were written after the code, on the day this
structure was adopted, reconstructed from the diffs and the conversation that
produced them. They are accurate about what was done and why. They are not
evidence that the process was followed prospectively for that work, and it would
be worth nothing to pretend otherwise: the point of the artifacts is that they
were reviewable *before* the work, and backfilled ones were not.

They are here because the alternative was starting the record at an arbitrary
point and losing the reasoning behind the code that already exists, and because
the mistakes list in `CLAUDE.md` is drawn from them.

From `0007` onward the order is the real one.

## The loop, concretely

```
intent.md      reviewed by a person, before anything is built
    ↓
spec.md        reviewed by a person; disagreements are cheap here
    ↓
plan.md        names the files, the order, and the tests
    ↓
build          agent writes code and tests; make test is the feedback loop
    ↓
review         REVIEW.md passes, some by subagent; a person merges
    ↓
ship           CI, then a release cut through the cut-a-release skill
    ↓
evals          promises checked on every pull request; a breach starts a new intent
```

## Repository map

```
CLAUDE.md                  institutional knowledge, loaded automatically
REVIEW.md                  the review passes every change is held to
docs/ai-native-sdlc.md     this document
intent/<n>-<slug>/         intent, spec, plan per unit of change
.claude/settings.json      permissions and the hook wiring
.claude/hooks/             production-gate.sh, the approval gates
.claude/skills/            procedures that load when relevant
.claude/agents/            reviewers with narrow mandates
evals/                     product promises, checked in CI
.github/workflows/         ci.yml, agent-evals.yml, pages.yml
app/                       the application and its tests
site/                      the landing page
design/                    brand kit and wordmark
```
