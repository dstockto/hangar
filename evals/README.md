# Evals

Behavioural checks on the properties that must stay true regardless of how the
code is refactored. They are not unit tests: the unit tests in `app/Tests` prove
the implementation works, and these prove the *product promises* still hold.

Each `.json` file is one case: an id, the promise in a sentence, and a command
whose exit status is the verdict. `check.sh` runs them all.

```sh
evals/check.sh          # all cases
evals/check.sh security # only ids beginning "security"
```

CI runs this on every pull request via `.github/workflows/agent-evals.yml`, and
a failure blocks the merge.

## Why these and not more

Every case here exists because the property it protects was once broken, or is
the kind of thing a plausible refactor would quietly break. A case that has never
been able to fail is noise.

## Prove a new case can fail, before adding it

Plant the mistake the case is meant to catch, run the case, and watch it fail.
Then take the mistake back out and watch it pass. Do it for changes to an
existing case too.

This is not ceremony. `security-no-force-unwrapped-endpoints` sat here green for
weeks while catching nothing: its regex escaped a parenthesis in a way `grep`
read as an unbalanced group, so `grep` exited 2, the leading `!` turned that
error into a pass, and the case reported success no matter what the source said.
A case built as `! grep ...` passes when the grep is broken, which is the worst
possible failure mode for a guard.
