# Plan: credential advice per profile type

1. `HangarCore/CredentialAdvice.swift`, new. Classifiers for "looks expired" and
   "looks rejected", then a decision per profile shape.
2. `FleetStore`: read the attempted profile before resolving, publish
   `credentialAdvice`, and delete `presentable`'s hardcoded SSO branch.
3. `Preflight.credentialsCheck`: take an `Advice?`.
4. `MenuBarController`: gate "Copy Login Command" on `advice.command`; copy that
   command rather than rebuilding one.
5. `SetupWindow`: pass the advice through.

## Tests

`CredentialAdviceTests`, one per row of the spec table, plus:

- The regression that motivated it: static keys never see an SSO command.
- An unrelated 503 passes through with its own text.
- A missing profile is reported as itself.
- The setup check offers a remedy only when one applies.
