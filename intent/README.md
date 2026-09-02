# Intent

One directory per unit of change, numbered in the order the work started. Each
holds up to three artifacts, written in this order:

| File | Stage | Answers |
|---|---|---|
| `intent.md` | Plan | Which question surfaced this, what was actually true, and what was decided |
| `spec.md` | Design | What the behaviour will be, precisely enough to disagree with |
| `plan.md` | Build | Which files change, in what order, and which tests prove it |

An `intent.md` here leads with the question that produced the work, not a
template. That is deliberate: the question is the reusable part. "If someone
downloads this for their fleet, does it work?" found more than any checklist
did, and reads back years later in a way that "## Problem" does not.

The point is that each stage is reviewable before the next one costs anything.
Disagreeing with a paragraph in `intent.md` is cheap; disagreeing with a merged
branch is not.

Small changes do not need all three. A one-line fix needs a commit message. The
threshold is roughly: if it changes behaviour a user could notice, or it touches
credentials, `ssh_config`, or the updater, it gets an `intent.md`.

`0001` through `0007` were written after the fact, on the day the workflow was
adopted, from the actual diffs and the conversation that produced them, and they
quote the questions that were genuinely asked. They are accurate about what was
done and why. They are not a pretence that the process was followed
prospectively; see [docs/ai-native-sdlc.md](../docs/ai-native-sdlc.md).
`0008` onward were written in order.

## Status

| Intent | Title | State |
|---|---|---|
| 0001 | Public release hardening | Shipped |
| 0002 | Swift 6 language mode | Shipped |
| 0003 | Configurable tag mapping | Shipped |
| 0004 | Credential advice per profile type | Shipped |
| 0005 | Automatic updates with in-place install | Shipped |
| 0006 | Landing page | Shipped |
| 0007 | Layered app icon | Open |
| 0008 | ssh argument and pattern injection | Shipped |
| 0009 | Tag picker on the setup screen | Shipped |
| 0010 | Composable menu levels | Shipped |
| 0011 | Reinstall behaves like one, and reset | Shipped |
