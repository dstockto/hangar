# Intent: build in Swift 6 language mode

## Problem

The package declared `swift-tools-version:6.0` but pinned every target to
`.swiftLanguageMode(.v5)`, so Swift 6's concurrency checking never ran. The code
had unsynchronized mutable global state that compiled only because nobody was
checking, and the pin was going to get harder to remove the longer it sat.

## Outcome

Every target builds in Swift 6 language mode, warning-free, with no
`@unchecked Sendable` and no `nonisolated(unsafe)`. A future change that
introduces a data race fails the build instead of shipping.

## Constraints

- No behaviour change. This is a compile-time property.
- If a fix needs an escape hatch, the design is wrong; change the design.

## Out of scope

Swift 7 upcoming-feature flags.
