# 0002: a language mode that was declared and not used

## How this came about

The instruction was short: *let's do a full full Swift 6.*

The package already said `swift-tools-version:6.0`, which reads as modern, but
every target carried `.swiftLanguageMode(.v5)`. So Swift 6's concurrency checking
had never run. The pin was doing real work: it was hiding unsynchronized mutable
global state that compiled only because nothing was looking.

The longer that sits, the harder it gets to remove, because more code accretes
against the unchecked assumption.

## The rule that made it worth doing

No escape hatches. If a fix needs `@unchecked Sendable` or
`nonisolated(unsafe)`, the design is wrong and the design changes. An escape
hatch turns a compile-time guarantee back into a comment.

That rule held. Nothing in the migration needed either.

## What the compiler found

- **Stored statics of non-Sendable types.** `SSO.iso` held an
  `ISO8601DateFormatter`; `Brand.Font` held seven `NSFont`s. Both became computed
  properties, which also made `Brand.Font` consistent with `Brand.Color` directly
  above it, already computed for the same reason.
- **Types that should always have been `Sendable`.** `SearchEntry` and
  `Fuzzy.Query` hold only `Instance`, `String` and `ContiguousArray<UInt8>`, and
  `FleetStore` publishes `[SearchEntry]` across isolation boundaries. The
  conformance was owed, not added.
- **Completion handlers crossing into a task**, in the updater.
- **Main-actor state touched from a nonisolated closure**, in the theme-change
  observer.
- **Two dead enum cases.** `Preflight.Remedy.installTerminal` was never
  constructed, and `.none` collided with `Optional.none` at its only use, which
  is what the compiler was warning about. Removing both cleared the warning and
  the dead code together.

## What was learned about verifying it

A concurrency change that compiles can still trap at runtime, so compiling was
not accepted as done. The built app was launched against a real account, left
running through a full refresh, and checked for crash reports before this was
called finished. It also wrote its ssh include correctly, which incidentally
confirmed two fixes from 0001 in production conditions.

## Proof

Clean release build, zero errors and zero warnings, from an empty `.build`. The
existing 98 cases were the regression net and not one expectation changed.
