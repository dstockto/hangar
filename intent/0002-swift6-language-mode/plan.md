# Plan: Swift 6 language mode

1. Strip the language-mode pin from `Package.swift`. Build and collect every
   diagnostic before changing any code, so the surface is known.
2. `HangarCore` first, since everything depends on it: `SSO.iso`,
   `Preflight.Remedy`.
3. `Hangar`: `Brand.Font`, `StatusGlyph`, `MenuBarController`'s observer,
   `Updates`' closures.
4. `Fuzzy`: `Sendable` on `SearchEntry` and `Query`, surfaced by the test target
   rather than the app.
5. Clean rebuild of both configurations, then `make test`.
6. Runtime check, because a concurrency change that compiles can still trap:
   launch the built app, let it refresh against a real account, confirm it writes
   the ssh include and produces no crash report.

## Tests

The existing 98 cases are the regression net; the migration must not change a
single expectation. `Sendable` on the search types is proved by the test target
compiling at all, since `SearchPerformanceTests` holds a static fleet.
