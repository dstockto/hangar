# Hangar Wordmark

Primary site lockup for Hangar. The wordmark is custom vector geometry, not live text, so it renders consistently without webfonts.

## Files

- `hangar-wordmark-dark.svg` primary lockup for dark backgrounds.
- `hangar-wordmark-light.svg` primary lockup for light backgrounds.
- `hangar-wordmark-mono-black.svg` single-color black lockup.
- `hangar-wordmark-mono-white.svg` single-color white lockup.
- Matching `@2x.png` files: raster fallback only.

## Site use

Use an SVG in the header at `width: 154px; height: auto`. Increase to 180–220 px in a footer or large brand moment. Do not render the lockup below 132 px wide; use the standalone app mark below that size.

Maintain clear space equal to the aircraft fuselage width on every side. Do not recolor individual letters, add a shadow, stretch, rotate, or place it on a busy image.

```html
<picture class="brand-lockup">
  <source srcset="/hangar/assets/hangar-wordmark-dark.svg" media="(prefers-color-scheme: dark)">
  <img src="/hangar/assets/hangar-wordmark-light.svg" width="420" height="96" alt="Hangar">
</picture>
```

