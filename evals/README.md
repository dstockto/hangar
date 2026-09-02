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
