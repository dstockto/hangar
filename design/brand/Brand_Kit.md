# Hangar Brand Kit

## 1. Positioning

**Tagline:** Your fleet, one keystroke away.

**GitHub descriptor:** A native macOS launcher that turns changing EC2 instances into stable, searchable SSH targets.

**30-word elevator description:** Hangar turns volatile EC2 identities into stable, searchable host aliases, letting infrastructure engineers find, connect to, copy, and reuse SSH targets instantly, without a server, external CLI, account, or runtime dependency.

## 2. App icon

### Concept A: Open Bay

**Idea:** A top-down aircraft sits inside the unmistakable negative-space opening of an industrial hangar: fleet, place, and selection in one silhouette.

**Geometry:** A 656-unit-wide gabled enclosure uses a 96-unit frame; its opening follows the roof at a 29.8° pitch, while a centered aircraft occupies 336 × 418 units and intentionally breaks the lower edge.

### Concept B: Taxiway Switch

**Idea:** One aircraft branches from three taxi lanes onto a selected route, expressing fuzzy search resolving a large fleet to one host.

**Geometry:** Three 72-unit vertical lanes on 176-unit centers converge through two 45° elbows into one 104-unit central lane; a 220 × 300 top-down aircraft caps the selected lane.

### Concept C: Bay Index

**Idea:** Three sharply cut aircraft-tail silhouettes sit in numbered-bay-like slots, evoking an indexed fleet without letters or numerals.

**Geometry:** A 704 × 560 rectangular shed is divided by two 28-unit uprights into three equal bays; each bay contains a 124-unit-wide tail, with the center tail raised 88 units and filled in the accent color.

### Selected direction: Concept A, Open Bay

Author the source as full-canvas SVG layers at 1024 × 1024 and import the layers into Icon Composer. Do not pre-mask the source to a rounded rectangle and do not bake highlights or shadows; Icon Composer owns the platform enclosure, specular response, refraction, translucency, and system shadow. Apple’s current workflow is a single resolution-independent layered icon annotated for Default, Dark, and Mono modes, including clear and tinted presentations. ([Icon Composer](https://developer.apple.com/icon-composer/), [Apple app-icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons))

#### Master grid

- Canvas: `0,0–1024,1024`.
- Protected live area: `128,128–896,896`. No identity-bearing feature may extend outside it.
- Visual center: `(512, 512)`; aircraft and bay are mathematically centered on `x = 512`.
- Minimum surviving feature: 52 units at master size, equivalent to 0.8125 px at 16 px. Critical silhouette members are 72–104 units, equivalent to 1.125–1.625 px at 16 px.
- No outlines in the master mark. Separation comes from solid nested silhouettes, which remain stable under tinting and at small sizes.

#### Layer order, back to front

| Layer | Exact construction | Default fill | Dark fill | Mono annotation | Material |
|---|---|---:|---:|---:|---|
| 0. Field | Rectangle `0,0,1024,1024`; allow Icon Composer to apply the macOS enclosure | `#E7EDF1` | `#0E1115` | 12% white | **Glass:** low translucency, low refraction, automatic inner specular; no authored shadow |
| 1. Bay aperture | Closed polygon `(280,746) (280,430) (512,292) (744,430) (744,746)` | `#CBE9FF` | `#163A52` | 24% white | **Glass:** medium translucency, low blur, low refraction, inside specular |
| 2. Hangar shell | Compound even-odd path: outer `M176 746 L176 390 L512 190 L848 390 L848 746 Z`; subtract the Layer-1 polygon exactly | `#273039` | `#39424B` | 52% white | **Opaque:** no blur, no refraction; automatic outside specular only |
| 3. Aircraft | Compound path below | `#006EAD` | `#57B9FF` | 100% white | **Opaque:** no blur or refraction; subtle automatic outside specular |
| 4. Threshold | Rounded rectangle `x=280 y=742 w=464 h=40 r=20` | `#15191D` at 72% | `#F3F6F8` at 28% | 72% white | **Glass:** low translucency and low refraction; no shadow |

Aircraft path:

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <path fill="#57B9FF" d="M512 348
 C488 348 476 373 476 410
 L476 520
 L332 610
 L332 668
 L476 624
 L476 704
 L424 742
 L424 782
 L512 758
 L600 782
 L600 742
 L548 704
 L548 624
 L692 668
 L692 610
 L548 520
 L548 410
 C548 373 536 348 512 348 Z"/>
</svg>
```

#### Appearance behavior

- **Light:** Use the Default fills above. The darker opaque shell carries the silhouette; the pale-blue aperture reads as depth, not a gradient.
- **Dark:** Use the Dark fills above. Preserve the cyan aircraft as the only saturated element.
- **Clear:** Keep the shell and aircraft opaque. Only Field, Bay Aperture, and Threshold receive glass. Set the aperture’s clear-mode opacity no lower than 62%; the aircraft remains 100% opaque.
- **Tinted/Mono:** Supply one grayscale annotation: Field 12%, Aperture 24%, Shell 52%, Aircraft 100%, Threshold 72%. Do not create a color-dependent cutout.
- **Small-size acceptance:** At 16 pt, the required read is “gabled bay + central aircraft.” The wing tips, 144-unit span on either side, must remain separated from the shell by at least 52 units. At 32 pt, the outer gable must form a unique pentagonal silhouette before interior detail is perceived.
- **Export:** Keep one `.icon` source in the Xcode project. Export a flattened 1024 × 1024 PNG only for README/store use; it is not the rendering source.

## 3. Menubar glyph

### Production requirements

- Asset name: `HangarStatusTemplate` and `HangarStatusTemplate@2x`.
- Logical size: 18 × 18 pt. Raster fallback sizes: 18 × 18 px and 36 × 36 px.
- SVG viewBox: `0 0 18 18`; every visible pixel is black with alpha, no embedded color profile, background, stroke color, or opacity below 1.
- AppKit: set `image.isTemplate = true`; set `NSStatusItem.button.imagePosition = .imageOnly`.
- Optical bounds: `x=1–17`, `y=2–16`. Primary members are at least 1.5 units thick; no isolated one-unit dot.

### Primary: hangar plus aircraft

The roof-and-post silhouette establishes “hangar”; the centered top-view aircraft makes it unlike Wi-Fi, sync, home, eject, or generic chevron icons.

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  <path fill="#000" fill-rule="evenodd" d="M1 7.1 9 2l8 5.1V16h-3V8.8L9 5.6 4 8.8V16H1V7.1Zm8 0c-.62 0-1 .48-1 1.08v2.18l-2.8 1.8v1.34l2.8-.78v1.38l-1.1.86V16h4.2v-1.04l-1.1-.86v-1.38l2.8.78v-1.34l-2.8-1.8V8.18C10 7.58 9.62 7.1 9 7.1Z"/>
</svg>
```

### Alternate A: selected bay

Three bays reduce to one solid center bay; this is more abstract and more “fleet index” than aviation.

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  <path fill="#000" d="M1 6.5 9 2l8 4.5V16h-2.5V8L9 4.9 3.5 8v8H1V6.5Zm4 3h2.2V16H5V9.5Zm3 0h2v6.5H8V9.5Zm2.8 0H13V16h-2.2V9.5Z"/>
</svg>
```

### Alternate B: taxiway selection

A compact aircraft crosses a framed threshold line, emphasizing “board this host” over storage.

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  <path fill="#000" d="M2 3h14v2H2V3Zm7 1.5c-.72 0-1.1.55-1.1 1.28v2.55L3.5 11v1.55l4.4-1.25v2.05l-1.65 1.2V16h5.5v-1.45l-1.65-1.2V11.3l4.4 1.25V11l-4.4-2.67V5.78C10.1 5.05 9.72 4.5 9 4.5Z"/>
</svg>
```

Use the primary in production. Validate it as a template image at 16 physical pixels on light, dark, and highlighted menu bars. Reject any rasterization that closes the aircraft-to-post gaps or turns the roof into a continuous triangle.

## 4. Color palette

Dark mode is canonical. Colors do not encode host state alone: every state color is paired with a glyph or state label. Production uses a separate danger treatment and never reuses the running green.

### Dark appearance

| Token | Hex | Role | Approved foreground/background pair | WCAG contrast |
|---|---:|---|---|---:|
| `canvas` | `#111418` | Panel surround and opaque fallback | `text-primary` on `canvas` | 17.02:1 |
| `panel` | `#171B20` | Floating panel base under material | `text-primary` on `panel` | 15.94:1 |
| `surface-raised` | `#1D2228` | Search field and popover fallback | `text-primary`; `text-secondary` on `surface-raised` | 14.75:1; 7.54:1 |
| `text-primary` | `#F3F6F8` | Hostnames and primary labels | on `canvas`; on `panel` | 17.02:1; 15.94:1 |
| `text-secondary` | `#AAB3BD` | Metadata and group counts | on `canvas`; on `panel` | 8.70:1; 8.15:1 |
| `accent` | `#57B9FF` | Focus ring, key actions, matched substrings | on `panel` | 8.06:1 |
| `selection-bg` | `#163A52` | Selected host row | `#FFFFFF` on `selection-bg` | 11.92:1 |
| `state-running` | `#49C983` | Running glyph and text | on `panel` | 8.21:1 |
| `state-stopped` | `#B2BAC2` | Stopped glyph and text | on `panel` | 8.81:1 |
| `state-pending` | `#F0C15A` | Pending glyph and text | on `panel` | 10.28:1 |
| `state-terminated` | `#F07880` | Terminated glyph and text | on `panel` | 6.35:1 |
| `prod-bg` | `#45191F` | Production badge/background stripe | `prod-danger` on `prod-bg` | 6.69:1 |
| `prod-danger` | `#FF8C96` | Production-only danger accent | on `prod-bg` | 6.69:1 |

### Light appearance

| Token | Hex | Role | Approved foreground/background pair | WCAG contrast |
|---|---:|---|---|---:|
| `canvas` | `#F6F7F8` | Panel surround and opaque fallback | `text-primary` on `canvas` | 16.47:1 |
| `panel` | `#FFFFFF` | Floating panel base under material | `text-primary` on `panel` | 17.67:1 |
| `surface-raised` | `#E9EDF1` | Search field and popover fallback | `text-primary`; `text-secondary` on `surface-raised` | 15.02:1; 5.20:1 |
| `text-primary` | `#15191D` | Hostnames and primary labels | on `canvas`; on `panel` | 16.47:1; 17.67:1 |
| `text-secondary` | `#59636D` | Metadata and group counts | on `canvas`; on `panel` | 5.71:1; 6.12:1 |
| `accent` | `#006EAD` | Focus ring, key actions, matched substrings | on `panel` | 5.48:1 |
| `selection-bg` | `#D9EEFF` | Selected host row | `#004B77` on `selection-bg` | 7.75:1 |
| `state-running` | `#167548` | Running glyph and text | on `panel` | 5.72:1 |
| `state-stopped` | `#59636D` | Stopped glyph and text | on `panel` | 6.12:1 |
| `state-pending` | `#8A5A00` | Pending glyph and text | on `panel` | 5.93:1 |
| `state-terminated` | `#B32632` | Terminated glyph and text | on `panel` | 6.48:1 |
| `prod-bg` | `#FFE1E4` | Production badge/background stripe | `prod-danger` on `prod-bg` | 6.51:1 |
| `prod-danger` | `#A60017` | Production-only danger accent | on `prod-bg` | 6.51:1 |

Ratios use the WCAG 2.x relative-luminance formula `(Llighter + 0.05) / (Ldarker + 0.05)`, with sRGB linearization. Every approved text pair exceeds 4.5:1. On a selected row, switch primary text, metadata, and state glyphs to the listed selection foreground; keep a production badge on its own `prod-bg`. Do not place semantic colors on `surface-raised` without a new contrast check; the table is the implementation contract.

## 5. Typography

Use native macOS font APIs, not bundled font files. `SF Pro` means `.systemFont`; `SF Mono` means `NSFont.monospacedSystemFont` so installed OS metrics remain correct.

| Element | Face/API | Weight | Size | Line height | Tracking |
|---|---|---:|---:|---:|---:|
| Panel search field | SF Pro / `.systemFont` | Regular 400 | 18 pt | 24 pt | 0 |
| Host row primary | SF Mono / `.monospacedSystemFont` | Medium 500 | 13 pt | 18 pt | -0.1 pt |
| Host row secondary metadata | SF Pro / `.systemFont` | Regular 400 | 11 pt | 15 pt | 0 |
| Group header | SF Pro / `.systemFont` | Semibold 600 | 11 pt | 16 pt | +0.25 pt |
| Menubar menu item | System menu font / `.menuFont` | Regular | 13 pt nominal | System-managed | System-managed |
| Keyboard shortcut hint | SF Mono / `.monospacedSystemFont` | Regular 400 | 11 pt | 15 pt | 0 |

- Host aliases earn monospace because they are scanned character-by-character, copied into terminals, and often differ only by an ordinal. Metadata stays proportional to reduce noise and width.
- Primary host text is one line. Truncate in the middle, not the tail: `prod-payments-xfer-…-7c91.internal`. Preserve at least the first 18 and last 12 characters when width permits.
- Never truncate the matched span. If the fuzzy match crosses the removed center, shift the truncation window so the full match and 4 characters of context on each side remain visible.
- Expose the full hostname in an accessibility label and in a tooltip after 600 ms hover. Copy and SSH actions always use the complete underlying value.
- Use tabular numerals for ordinals, host counts, and cache ages.

## 6. The floating panel

**Assumption:** The main panel is an `NSPanel` presented on the active screen, not a menu attached to the status item.

- **Feel:** Immediate, calm, and tool-like: a command surface that appears already focused, not a miniature application window.
- **Material:** Use the macOS 26 Liquid Glass system material available to `NSVisualEffectView`; select a dark-appropriate HUD/popover material and let system vibrancy resolve against the current desktop. Place a `panel` color fallback beneath it at 86% opacity. Do not simulate glass with a static blur screenshot.
- **Window:** 640 pt wide; initial content height 456 pt; minimum 520 × 240; maximum 760 × 620. Center horizontally on the active screen and place its top edge 18% below the screen top. Corner radius 18 pt, system shadow only, 1 pt inside separator using `text-primary` at 8% opacity.
- **Search region:** 56 pt high. Search field inset 12 pt horizontally and 10 pt vertically. Search icon 16 pt, text baseline centered, clear button 16 pt.
- **Rows:** 48 pt each: 16 pt leading status/production rail, 8 pt gap, flexible text block, 12 pt trailing inset. Primary baseline at y=17; metadata baseline at y=35.
- **Spacing scale:** 4, 8, 12, 16, 24, 32 pt. Use 4 only inside compact metadata; 8 between inline facts; 12 for component insets; 16 for major horizontal edges; 24/32 only for empty states.
- **Selection:** One 40 pt-high rounded rectangle inset 4 pt vertically and 8 pt horizontally, radius 9 pt. Use `selection-bg`; add a 2 pt accent rail at x=8. Keyboard focus is additionally indicated by a 1.5 pt `accent` inner ring. Do not change the hostname’s weight on selection, which would cause layout jitter.
- **Production:** A 3 pt `prod-danger` rail runs the full 40 pt selection capsule height whether selected or not. Metadata begins with an uppercase `PROD` badge using `prod-bg`/`prod-danger`. No other environment gets red or pink.
- **Grouping:** Product is the sticky header, 24 pt high: semibold product name left, result count right. Environment appears as an 11 pt inline metadata token at the start of each row. Insert a 1 pt, 24%-opacity divider only when environment changes inside a product; do not add a second header row.
- **Chrome:** No title bar, traffic lights, toolbar, tabs, sidebar, or persistent footer. A 28 pt transient footer appears only when useful and shows `↩ Connect`, `⌘↩ Copy`, and cache age.

### Narrowing behavior: 250 hosts → 3

1. At 250 hosts, show the first 9 visible rows, sticky product header, scrollbar, total count, and cache age. Group ordering follows most recently used product, then alphabetical.
2. As characters arrive, update matches within one frame, preserve the current selection if it still matches, and animate only row removal/repositioning with a 90 ms ease-out. Do not fade text during typing.
3. Matched character runs change to `accent` and semibold; unmatched text stays primary. Never color each character with a gradient.
4. Below 12 results, remove sticky behavior and let headers scroll naturally. The panel keeps its outer height until 120 ms after typing stops, then collapses to content height with a 140 ms ease-out.
5. At 3 results, show exactly three 48 pt rows, only the product headers actually represented, and the shortcut footer. The first result is selected, but Return is never triggered automatically.

## 7. Iconography set

All interface glyphs use `currentColor`, a 1.5-unit stroke, no fill, square line caps, and miter joins. Keep them on a 16 × 16 viewBox and render at 16 pt or an exact integer multiple. State glyphs include geometry, not color alone.

### Environment

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path d="M2.75 3.25h3L8 5.5l2.25-2.25h3v9.5h-3L8 10.5l-2.25 2.25h-3z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter"/>
</svg>
```

### Product

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path d="m8 2.25 5 2.5v6.5l-5 2.5-5-2.5v-6.5zM3 4.75l5 2.5 5-2.5M8 7.25v6.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter"/>
</svg>
```

### Autoscaling group membership

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path d="M5 4.25h6M4 5.25 2.75 4 4 2.75M11 11.75H5M12 10.75 13.25 12 12 13.25M3.25 6.5v3M12.75 6.5v3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter"/>
</svg>
```

### Running

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <circle cx="8" cy="8" r="5.25" fill="none" stroke="currentColor" stroke-width="1.5"/>
  <path d="m6.75 5.5 3.5 2.5-3.5 2.5z" fill="currentColor" stroke="none"/>
</svg>
```

### Stopped

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <circle cx="8" cy="8" r="5.25" fill="none" stroke="currentColor" stroke-width="1.5"/>
  <path d="M6 6h4v4H6z" fill="currentColor" stroke="none"/>
</svg>
```

### Copied to clipboard

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path d="M5.25 4.25h-2v9h7v-2M6.25 2.75h6.5v7h-6.5zM8 6.5l1.25 1.25L11.5 5.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter"/>
</svg>
```

### Stale cache

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path d="M12.5 5.25A5.25 5.25 0 1 0 13.25 9M12.5 2.75v2.5H10M8 5v3.25l2 1.25" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter"/>
</svg>
```

## 8. Voice and tone

### Rules

1. **Lead with state, then action.** Say what happened in the first clause and the next recoverable step in the second.
2. **Use exact nouns.** Prefer “credentials,” “cache,” “host,” and the literal region or path over “something,” “session,” or “configuration.”
3. **Be terse without becoming cryptic.** One sentence for routine states; two only when recovery needs a command or consequence.
4. **Sound like a good CLI.** Sentence case, active voice, no exclamation points, cheerleading, apologies, or cute aviation metaphors in operational UI.
5. **Preserve copyable truth.** Commands, paths, regions, counts, and host aliases remain literal and use monospace styling.

| Original | Hangar string | Why |
|---|---|---|
| “No instances matched in us-west-2.” | **No hosts match in `us-west-2`.** | “Hosts” matches the user’s task, present tense reflects the live filter, and the region remains literal. |
| “Your AWS session looks stale; run aws sso login and retry.” | **Credentials expired. Run `aws sso login`, then retry.** | Removes hedging and “your,” names the failure precisely, and keeps the recovery command copyable. |
| “248 instances in us-west-2” | **248 hosts · `us-west-2`** | Converts a sentence into dense scan-friendly status while preserving count and scope. |
| “wrote ~/.ssh/config.d/hangar” | **SSH config updated: `~/.ssh/config.d/hangar`** | States the artifact and outcome before the implementation path; avoids log-style lowercase prose in UI. |

## 9. Copy deck

### Menubar dropdown

Use this order and punctuation:

1. **Open Hangar**: shortcut `⌘⇧H`
2. **Refresh Fleet**: shortcut `⌘R`
3. **248 hosts · `us-west-2`**: disabled status row; substitute live count/region
4. **Cache updated 2 min ago**: disabled status row; show stale glyph after the freshness threshold
5. Separator
6. **SSH Config…**
7. **Settings…**: shortcut `⌘,`
8. Separator
9. **About Hangar**
10. **Quit Hangar**: shortcut `⌘Q`

Do not add “Check for Updates” unless the chosen updater requires it. Do not put destructive or account language in this menu; there is no Hangar account.

### First-run onboarding: two screens

Two screens are enough because there is no signup, server, browser handoff, or mandatory tutorial.

#### Screen 1: Find your fleet

**Title:** Your fleet, one keystroke away.

**Body:** Hangar reads AWS profiles and cached credentials from your home directory. Nothing is uploaded, and no Hangar account is required.

**Detected state:** `3 profiles found` or `No AWS profiles found`

**Controls:** Profile pop-up labeled **AWS profile**; region multi-select labeled **Regions**; primary button **Discover Hosts**; secondary link **What Hangar reads**.

**Disclosure text:** `~/.aws/config`, `~/.aws/credentials`, EC2 instance tags, and `~/.ssh/config.d/hangar`. Hangar never reads private keys.

#### Screen 2: Ready

**Title:** Hangar is ready.

**Body:** Press `⌘⇧H`, type a host, and press Return to connect. Press `⌘↩` to copy the SSH command.

**Status:** `248 hosts indexed · 6 products · 4 environments`

**Controls:** Primary button **Open Hangar**; checkbox **Write SSH config aliases** checked by default; link **Change shortcut**.

### Empty state

**Title:** No hosts found.

**Body:** Hangar found no tagged EC2 instances in the selected profiles and regions.

**Primary action:** **Refresh Fleet**

**Secondary action:** **Review Discovery Settings**

**Diagnostic line:** `Profile: platform-prod · Regions: us-west-2, us-east-1`

If the fleet exists but the search returns zero results, use the smaller inline state: **No hosts match “{query}”.** Do not show the full empty-state illustration.

### Expired-credentials state

**Title:** Credentials expired.

**Body:** Refresh credentials for `{profile}`, then retry discovery.

**Command:** `aws sso login --profile {profile}`

**Primary action:** **Copy Login Command**

**Secondary action:** **Retry**

**Footnote:** Hangar reads the refreshed credentials from `~/.aws`; it does not receive your sign-in details.

### README header block

```markdown
# Hangar

**Your fleet, one keystroke away.**

A native macOS launcher that turns changing EC2 instances into stable, searchable SSH targets.

Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>H</kbd>, type a few characters, and press <kbd>Return</kbd> to connect in iTerm2. Hangar discovers instances by tag, caches them locally, and writes stable aliases to an SSH config include, without a server or Hangar account.

[Download Hangar](#installation) · [Install](#installation) · [How discovery works](#discovery) · [Security](#security)
```

### Landing page description

Autoscaling should replace instances, not your memory. Hangar indexes tagged EC2 fleets across products and environments, gives every host a stable alias, and puts the right SSH target behind one global shortcut. Search from anywhere, press Return to open iTerm2, or copy the command for another tool. Hangar also writes a standard SSH config include, so the same aliases work with `ssh`, `scp`, `rsync`, Ansible, and VS Code Remote. Discovery and cache data stay on your Mac; there is no Hangar server, account, or telemetry dependency.

## 10. What to avoid

- **AWS orange, the AWS smile/arrow, service icons, or AWS typography:** implies affiliation and makes the product visually dependent on another brand.
- **Cloud outlines:** generic infrastructure shorthand that says “cloud dashboard,” not “find one machine in a fleet.”
- **Server racks or stacked server rectangles:** overused, visually noisy at menubar size, and inaccurate to the fleet/boarding metaphor.
- **Generic terminal prompts (`>_`, `$`, cursor blocks):** confusable with dozens of developer tools and describes the launch destination, not Hangar’s value.
- **Padlocks, shields, or keyholes:** falsely positions Hangar as a security or credential product.
- **Soft pastel gradients, violet-to-blue AI gradients, or candy-colored duotones:** read as consumer productivity or AI SaaS, not native infrastructure tooling.
- **Fintech navy plus neon green:** makes running-state green look like money/performance and gives the brand a trading-dashboard tone.
- **Airline wings, pilot badges, roundels, and travel pictograms:** turn the aviation metaphor into consumer travel branding.
- **Photoreal aircraft, rivets, vapor, and 3D hangar scenes:** fail at 16–32 pt and conflict with monochrome/tinted rendering.
- **Mascots, smiling airplanes, or anthropomorphic machines:** introduce a playful voice that senior operators will read as noise.
- **Rounded productivity tiles inside every row:** waste vertical space and weaken the keyboard-first hierarchy.
- **Red for generic errors or terminated instances when a production host is present:** production danger must remain uniquely identifiable; use the specified terminated red only with its terminated glyph and label.
