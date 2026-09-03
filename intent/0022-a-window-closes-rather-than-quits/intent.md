# 0022: a window closes rather than quitting

## How this came about

> when I do cmd+q on dashboard, I do not want the app in the menu bar to quit

Hangar lives in the menu bar. Every window it opens is something you finish with
and put down: a dashboard you consulted, a setup check you read, a host whose
login you fixed. The reflex that closes a window is Command-Q as often as
Command-W, and here it was taking the whole app out of the menu bar. The only
sign of that is the glyph quietly disappearing, and getting it back means finding
Hangar in the Applications folder again.

The panel has never had this problem. `HangarPanel.isDismissKey` has always read
Command-Q and Command-W as "close this overlay, never quit", and the README has
said so since the panel shipped. The ordinary windows were simply never given the
same rule, because they arrived later and inherited the standard menu.

## The change

- `HangarWindow`, an `NSWindow` that closes on the same keys the panel dismisses
  on, used by the dashboard, the setup check, the host editor and About.
- The app menu's **Quit Hangar** loses its Command-Q equivalent. Leaving it there
  would be a race between the menu and the window over the same keystroke, and
  the menu usually wins.

Quitting is still one click, from the menubar item that has always carried it.
That is the only thing that ends Hangar, which is what the Install section of the
README already promised.

## What this is not

It is not a claim that Command-Q should mean "close" in general. It means that
in an app with no Dock icon and no documents, whose whole life is a menubar
glyph, the cost of guessing wrong is asymmetric: closing a window you wanted open
costs a click, and quitting an app you wanted running costs finding it again.
