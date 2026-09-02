# Intent

One directory per unit of change, numbered in the order the work started. Each
holds up to three artifacts, written in this order:

| File | Stage | Answers |
|---|---|---|
| `intent.md` | Plan | What problem, for whom, under what constraints, and what is out of scope |
| `spec.md` | Design | What the behaviour will be, precisely enough to disagree with |
| `plan.md` | Build | Which files change, in what order, and which tests prove it |

The point is that each stage is reviewable before the next one costs anything.
Disagreeing with a paragraph in `intent.md` is cheap; disagreeing with a merged
branch is not.

Small changes do not need all three. A one-line fix needs a commit message. The
threshold is roughly: if it changes behaviour a user could notice, or it touches
credentials, `ssh_config`, or the updater, it gets an `intent.md`.

`0001` through `0006` were written after the fact, on the day the workflow was
adopted, from the actual diffs and the conversation that produced them. They are
accurate about what was done and why. They are not a pretence that the process
was followed prospectively; see [docs/ai-native-sdlc.md](../docs/ai-native-sdlc.md).

## Status

| Intent | Title | State |
|---|---|---|
| 0001 | Public release hardening | Shipped |
| 0002 | Swift 6 language mode | Shipped |
| 0003 | Configurable tag mapping | Shipped |
| 0004 | Credential advice per profile type | Shipped |
| 0005 | Automatic updates with in-place install | Shipped |
| 0006 | Landing page | Built, deployment pending a Pages setting |
