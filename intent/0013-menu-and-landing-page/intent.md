# 0013: the menu says what it means, and the page shows it

## How this came about

Three questions in a row, all after looking at the actual menu rather than the
code.

> can we use EC2 glyph for the hosts in the final ssh submenu ?

> and also for the top level in the menu drop down, do you want to add a group
> label like hosts ? instances ? .... and obviously if we can reach aws and
> create an inventory of that, don't show ? or say no hosts found ?

> also update readme and app homepage with new fresh screenshots and
> functionality

## The glyph

Host leaves carried a play-circle or a stop-circle, so the glyph column answered
"is it running" and never answered "what is this row". Every leaf now carries the
EC2 chip, the same mark the count row uses, and state is carried by the label:
a host that is not running reads `web-1  (stopped)` in secondary text.

The glyph could have been tinted green instead. It cannot: a menu image has to
stay a template or macOS stops inverting it against the blue of a highlighted
row. The search panel still shows the colour-tinted state glyph, with an
accessibility label, which is where state-at-a-glance actually belongs.

## The heading

`HOSTS`, in the same small-caps as the Settings sections. "Hosts" rather than
"Instances" because every other string in the app says hosts, and what the row
does is ssh to one.

## The claim that was not true

The empty case printed "No hosts found." whenever the list was empty, including
when the fetch had failed. The result, on an expired SSO session, was an error
row saying the session expired followed by a second diagnosis saying the account
has no hosts. One of those was a lie, and it is the one that sounds like the
user's problem rather than Hangar's.

"No hosts found" is a claim about the AWS account, so it is now made only after
Hangar has reached AWS. The decision moved to `FleetSection.classify` in the
core, because it is not an AppKit decision and because it is worth a test:

| State | Section |
|---|---|
| Hosts known | the cascade |
| Reached AWS, zero instances | "No hosts found." |
| First fetch failed, nothing cached | nothing; the error row above is the story |
| First fetch in flight | "Looking for hosts…" |
| Never fetched | "No inventory yet. Refresh Fleet builds one." |

The section owns its separator, so the hidden case leaves no double rule.

## The page

The landing page had no screenshots, and the hero panel was a hand-built CSS
representation with a comment explaining that a typing animation was deliberately
left out. That call is reversed: the narrowing is the product, so the panel now
types `payments prod web` and drops the rows that stop matching, once, when it
scrolls into view, with a Replay button. It plays inside a fixed-height stage, so
nothing below it moves; that was the original objection and it is answered by
reserving the space rather than by staying still.

Screenshots are real, taken from a running Hangar pointed at a throwaway home
directory holding a fictional fleet, so nobody's hostnames are on the page. The
script that sets that up lives outside the repo.

Two smaller corrections on the same page: the proof strip claimed "One global
key" where it could simply show `⌘⇧H`, and "AWS CLI: Not required" was true of
running Hangar and not of the first `aws sso login` on a machine. The cell now
reads "Not needed to run", and the credentials card says where the CLI still
comes in.
