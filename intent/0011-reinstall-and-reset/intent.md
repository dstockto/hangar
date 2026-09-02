# 0011: a reinstall that behaves like one

## How this came about

Three observations in quick succession, all about the same underlying thing:
Hangar's state outliving the thing that created it.

> shouldn't these be a popup?

about the heads-up display answering **Check for Updates**.

> also add a cache invalidation for hangar .... like a reset and start over fresh

> when I drag and drop the app into recycle bin and install a dmg, it should
> start like a freshly installed app

## The popup

A fading badge is right for something the user did not ask about and wrong for
the answer to a question they just asked. "Hangar 0.2.0 is current" appeared for
1.6 seconds and then took the answer away with it.

An explicit check now returns a dialog that waits to be dismissed, with a Release
Notes button. Failures the same. The badge stays for the unprompted daily check,
which is exactly the case it suits.

## The reinstall

Deleting an app on macOS leaves its support files behind. That is correct
platform behaviour, which is why uninstallers exist, and it is the wrong
behaviour for someone who dragged Hangar to the Trash specifically to start over.
They got the old cache, the old settings and no setup screen, which reads as "the
delete did not work".

The question was how to tell a reinstall from an ordinary launch, since a
reinstalled app is byte-identical to the one that was deleted. The answer is the
bundle's creation date: a copied bundle gets a new one. So Hangar records the
version and the bundle creation date it last ran from, and classifies:

| Seen | Meaning | Behaviour |
|---|---|---|
| No record | First run | Setup |
| Higher version | Upgrade | Nothing; settings kept silently |
| Same or lower version, newer bundle | Reinstall | Cache dropped, setup runs |
| Same bundle | Ordinary launch | Nothing |

The upgrade row is the one that needed care. An in-place update also writes a new
bundle, so without the version check every automatic update would have dumped the
user back into the setup screen.

A second of tolerance on the timestamp, because a filesystem copy can round it
and a real reinstall moves it by far more.

## The decision that is a judgement call

A reinstall drops the cache and keeps the settings.

"Like a freshly installed app" read literally means dropping the config too. It is
not done, because the most likely reason to delete and reinstall is a binary that
is misbehaving, and silently discarding someone's tag mapping and menu levels
while they are trying to fix something else is a bad trade. The visible behaviour
is what was asked for: setup runs, the fleet is fetched rather than remembered.
**Reset Hangar** is one menu item away for anyone who genuinely wants nothing
kept, and now says so.

## Reset

Two scopes, because they answer different questions. "The fleet looks wrong"
wants the cache gone. "I want to start over" wants the settings gone too. Both
confirm exactly which files go before touching anything.

The part worth testing is not what reset removes but what it must never remove.
`HangarResetTests` asserts every path is either inside `~/.hangar/` or is exactly
the ssh file Hangar generates, so the blast radius cannot widen past the user's
own `~/.ssh/config`, their `known_hosts` or anything under `~/.aws` without the
suite failing.

## Proof

`InstallStateTests` covers all four classifications plus timestamp jitter, a
missing bundle date, an unreadable record, and the file mode.
`HangarResetTests` covers the scopes and pins the blast radius. 189 tests green.
