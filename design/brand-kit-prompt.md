You are a senior brand and product designer who specializes in developer tools and
native macOS apps. Produce a complete, executable brand kit for an app called **Hangar**.
Assume I will hand your output straight to an engineer and an illustrator, so be
specific enough to build from. No preamble, no summary at the end.

## The product

Hangar is a native macOS menubar utility for DevOps and SRE engineers who manage
fleets of AWS EC2 instances across many environments.

The problem it solves: instances in autoscaling groups get machine-generated
hostnames that change every time an instance is replaced, so engineers cannot
remember or bookmark them. Finding the box you need to ssh into means running AWS
CLI queries and copying long hostnames by hand.

How it works:
- It discovers every EC2 instance in an account by tag (product, environment,
  environment name, role) and caches the result locally.
- A global hotkey (default cmd+shift+H) summons a floating panel from anywhere in
  the OS. You type a few characters, fuzzy-match a host, and press Return to open
  an ssh session in iTerm2. Cmd+Return copies the ssh command instead.
- It also writes an ssh_config include file, so `ssh prod-xfer-1` works from any
  terminal, scp, rsync, Ansible, or VS Code Remote.
- It is fully self-contained: no external CLI, no server, no account. Everything it
  reads lives in the user's home directory.

The name metaphor: a hangar is where you keep your fleet, and where you walk in and
board a specific aircraft. Aviation and fleet imagery is on-brand. It should feel
like infrastructure, not like a consumer app.

## Audience and positioning

Senior infrastructure engineers. Keyboard-driven, terminal-resident, allergic to
bloat and to anything that looks like enterprise SaaS marketing. They already own
iTerm2, Raycast, and a pile of CLI tools. Hangar has to look like it belongs next
to those, not next to a CRM. Precise, fast, quiet, slightly industrial.

## Deliverables, in this order

1. **Positioning.** A tagline of six words or fewer, a one-line descriptor for a
   GitHub repo, and a 30-word elevator description.

2. **App icon.** Three genuinely distinct concepts, each with a one-sentence idea
   and a precise description of the geometry. Then pick the strongest and specify
   it on a 1024x1024 grid: shapes, coordinates or proportions, stroke weights,
   fills, layer order. Requirements:
   - Must satisfy macOS 26 icon conventions: authored as layered art for Icon
     Composer, rendering correctly in the light, dark, clear, and tinted
     appearances. No baked drop shadows, no text, no photographic detail.
   - Must stay legible at 16pt in a Finder list, and read as a distinct silhouette
     at 32pt in the Dock.
   - Say explicitly which layers get the glass treatment and which stay opaque.

3. **Menubar glyph.** This is the most important asset. A single-color template
   image for NSStatusItem: alpha channel only, black fill, no color, 18x18pt at 1x
   and 2x. Deliver working inline SVG code on an 18x18 viewBox. It has to read
   unmistakably at 16 physical pixels, survive macOS inverting it for dark mode
   and for a highlighted menubar, and not be confusable with the dozen other
   menubar icons a developer already has. Give one primary and two alternates.

4. **Color palette.** Hex codes in a table with a role per color, for light and
   dark appearances. Dark mode is the primary design target. Include:
   - One accent color for interactive and selected states.
   - Semantic colors for instance state: running, stopped, pending, terminated.
   - A distinct danger accent used only to mark production hosts, so a user can
     never confuse a prod box with a sandbox one at a glance.
   - Verified WCAG AA contrast ratios for every foreground and background pair
     you propose, with the computed ratio stated.

5. **Typography.** A system-font stack (SF Pro, SF Mono) with concrete weights,
   sizes, and line heights for: panel search field, host row primary text,
   host row secondary metadata, group headers, menubar menu items. Hostnames are
   long and monospaced-adjacent, so say how to handle truncation and where the
   monospace face earns its place.

6. **The floating panel.** How it should feel and look: material and translucency
   in the macOS 26 Liquid Glass idiom, corner radius, panel width, row height, a
   spacing scale in points, how the selected row is indicated, how grouping by
   product and environment is expressed visually without wasting vertical space.
   State what happens visually as the user narrows 250 hosts to 3.

7. **Iconography set.** Small glyphs, SVG on a 16x16 viewBox, for: environment,
   product, autoscaling group membership, running, stopped, copied-to-clipboard,
   stale cache. Consistent stroke weight and terminal style across the set.

8. **Voice and tone.** Five concrete rules. Then rewrite these four real strings
   from the app in that voice, and explain each choice in one line:
   - "No instances matched in us-west-2."
   - "Your AWS session looks stale; run aws sso login and retry."
   - "248 instances in us-west-2"
   - "wrote ~/.ssh/config.d/hangar"

9. **Copy deck.** Menubar dropdown item labels, first-run onboarding (three screens
   maximum, or argue for fewer), the empty state, the expired-credentials state,
   the README header block, and a one-paragraph landing page description.

10. **What to avoid.** A short list of the specific clichés, colors, and shapes
    this brand should never use, with the reason for each.

## Hard constraints

- No AWS trademarks, no AWS logo, no AWS orange. The app is unaffiliated.
- No cloud outlines, no server racks, no generic terminal prompt glyphs, no
  padlocks. Those are the four clichés of this category.
- Do not make it look like a fintech or productivity SaaS. No soft pastel gradients,
  no 3D blobs, no illustration-style mascots.
- Dark mode first, light mode must still be excellent.
- Everything must survive being monochrome, because the menubar demands it.

## Output format

Markdown. Sections numbered as above. Color values in tables. All SVG as working
code in fenced blocks. Geometry described numerically, not vaguely. If you must make
an assumption, state it in one line and continue rather than asking me a question.
