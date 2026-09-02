# Spec: Swift 6 language mode

Remove `swiftSettings: [.swiftLanguageMode(.v5)]` from all targets. Then, for each
diagnostic, fix the cause rather than silencing it:

- **Stored statics of non-Sendable types.** `SSO.iso` held an
  `ISO8601DateFormatter`; `Brand.Font` held seven `NSFont`s. Both become computed
  properties. A formatter per token refresh and a font per draw are free, and
  `Brand.Color` was already computed, so this makes the file internally
  consistent.
- **Types that should always have been Sendable.** `SearchEntry` and `Fuzzy.Query`
  hold only `Instance`, `String` and `ContiguousArray<UInt8>`, and `FleetStore`
  publishes `[SearchEntry]` across isolation boundaries. Declare the conformance.
- **Completion handlers crossing into a task.** `Updates.check` and
  `Updates.stage` take `@Sendable` closures; `StageResult` and its `swap` closure
  become `Sendable`.
- **Main-actor state touched from a nonisolated closure.** `StatusGlyph` is
  `@MainActor` because its cache is mutable static state and only the main thread
  draws a menubar item; the theme-change observer moves its call inside the
  existing `Task { @MainActor }`.
- **Dead enum cases producing an ambiguity warning.** `Preflight.Remedy` had
  `installTerminal`, never constructed, and `.none`, which collided with
  `Optional.none` at its only use. Both are removed.

## Acceptance

`swift build -c release` and `swift test` from a clean `.build`, zero errors and
zero warnings. The app launches, refreshes, and writes its ssh include.
