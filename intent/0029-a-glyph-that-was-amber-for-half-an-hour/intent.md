# 0029: a glyph that was amber for half an hour

## How this came about

> why is menu bar icon most of the time yellow instead of green

The menubar aircraft has four states and one of them was winning almost always.
Not because the fleet was unhealthy: the log says every refresh in the last day
finished cleanly in 1.3 to 2.1 seconds, on a 30 minute timer. Green should have
been on screen 99.9% of the time.

## What was actually true

The amber was the refresh pulse, and it never stopped.

`startPulse` schedules a 20 Hz `Timer` whose body does not draw. It queues the
draw into a detached `Task { @MainActor }`:

```swift
pulse = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
    Task { @MainActor in ... self.drawPulse(intensity: ...) }
}
```

`stopPulse` invalidates the timer and `updateStatusImage` repaints the settled
glyph. But a frame that had already fired is sitting in the actor queue with
nothing to tell it the refresh is over, so it lands *after* the repaint and puts
the pulse colour back. `drawPulse` checked no state at all. Nothing repaints
again until the next refresh, which has the same race, so the icon sat amber for
the whole 30 minute window and usually for the one after it.

A timer you can invalidate is not a timer you can stop when the work happens one
hop away from the tick. The frame has to ask the store whether it is still wanted.

Two more things were wrong once you look at what the colour was claiming:

**There was no aging state.** The glyph was green or it was the plain template.
"Refreshed four minutes ago" and "refreshed yesterday, every attempt since has
failed" were the same picture. The only thing separating them was a tooltip
nobody hovers.

**Health was never recomputed.** `updateStatusImage` ran when `fetchedAt` or
`status` published. Both only change at a refresh, which is the one moment the
cache's age is not worth reporting. A cache going stale is a thing that happens
while nothing at all is being published.

## What was decided

One scale, four colours, from a classifier in `HangarCore` rather than from a
condition spelled out at each call site:

| State | Glyph | When |
|---|---|---|
| `refreshing` | breathing green | a fetch is in flight |
| `fresh` | steady green | inside `stale_after_minutes`, default 60 |
| `aging` | amber | past that, inside `healthy_within_hours` |
| `stale` | red | past that, or the last fetch failed |
| `unknown` | plain template | nothing was ever cached |

The pulse is green rather than amber because the cache underneath a refresh is
still the one on screen, and because amber now means something else. `unknown` is
kept apart from `stale` deliberately: "out of date" is a claim about a fleet, and
on a first launch there is no fleet on screen to make it about.

`CacheHealth.classify` is pure and takes `now`, so the boundaries are testable
without waiting an hour. `FleetStore.isHealthy` and the command line's own
`healthy_within_hours` arithmetic both went through it, so the glyph and the
`hangar` warning cannot drift apart. A 60 second ticker recomputes, because
health is a function of elapsed time and nothing publishes the passage of time.

## Also in this change

**Check for Updates left Settings.** It was a section inside the Settings
submenu, and a duplicate checkbox and channel popup in the setup window. Two
controls for one setting, both of them two levels down from the menu, for the one
thing in the app that is worth acting on the day it appears. It is now its own
top-level item in the menubar menu: Check Now, Install when there is something to
install, Check Daily, the channel, and the installed version. The setup window's
copy is gone rather than kept in sync.
