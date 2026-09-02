# 0018: a window you can get back to

## How this came about

> also setup check screen is not showing up on apps list when I do app switcher
> like cmd + tab

Correct, and it follows from a deliberate choice: Hangar is `.accessory`, which
is what keeps it out of the Dock and out of the app switcher. That is right for
a menubar utility and wrong for a window that is on screen, because command-tab
is how people get back to a window they clicked away from. The setup screen was
reachable only through the menubar item that opened it.

## The decision

The activation policy follows the windows. `.regular` while a real window is
open, `.accessory` again when the last one closes. Hangar appears in the switcher
and the Dock exactly as long as it has a window worth switching to.

The floating panel is excluded. It is a `.nonactivatingPanel` that dismisses when
the click lands elsewhere, so putting Hangar in the app switcher for its lifetime
would be both wrong and useless.

The cost is a Dock icon while a window is open, which the README claimed never
happens. The README is updated rather than the behaviour: being unable to reach
an open window is worse than a Dock icon that comes and goes with it.
