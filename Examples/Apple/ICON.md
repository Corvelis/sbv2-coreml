# Sample app icon

The icon combines a speech bubble and waveform on teal, matching the sample's accent color.
The built-in image generation tool produced the artwork. The iOS icon is opaque and square;
the macOS variant has a rounded tile, padding and real alpha transparency.
`sips` resizes the artwork to the required asset catalog sizes without changing its design.

- iOS master: `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
- macOS master: `Assets.xcassets/AppIconMac.appiconset/AppIconMac-1024.png`
- Both targets include `Assets.xcassets` in their Resources phase.
- The optional project generator preserves the app icon and accent-color settings.

## Generation prompt

```text
Use case: logo-brand
Asset type: production app icon for the SBV2 Core ML speech synthesis sample on iPhone and Mac, square 1024 x 1024.
Primary request: a smart, minimal, polished icon that communicates speech becoming an audio waveform. A single bold ivory speech bubble containing five rounded vertical waveform bars. The mark should be distinctive, calm, geometric, optically balanced, and instantly legible at small sizes.
Scene/backdrop: opaque full-bleed deep teal background, with a very subtle teal gradient that matches a restrained native Apple app interface.
Style/medium: crisp premium digital icon, simple sculpted geometry, subtle depth only, no photorealism, no noisy textures.
Composition/framing: centered glyph occupying approximately 60 percent of the square, generous consistent negative space. Edge-to-edge square canvas with no pre-rounded outside corners and no surrounding presentation mockup.
Text: none.
Constraints: exactly one icon, no lettering, no watermark, no branding from other companies, no microphone, no robot or character, no extra symbols. Opaque background, no alpha.
```

## macOS adaptation prompt

```text
Use case: precise-object-edit
Asset type: macOS app icon for the same SBV2 Core ML speech synthesis sample.
Edit target: the attached generated teal speech-bubble and waveform app icon.
Primary request: preserve the existing icon design exactly, but present the square teal icon as a macOS rounded-square tile with genuinely transparent outside corners and a modest transparent margin on all sides. Keep the teal tile about 82 percent of the total square canvas width. Give the tile smooth superellipse corners and a very subtle small soft shadow, appropriate for the macOS Dock.
Constraints: keep the ivory speech-bubble/waveform mark, its geometry, the existing teal gradient and their relative placement within the tile unchanged. Change only the outer silhouette/padding. No text, no new symbols, no mockup, no white or checkerboard background. Output a square 1024 x 1024 PNG with real alpha transparency.
```
