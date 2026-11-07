# Original switcher icon — 2026-11-07

For this multi-account utility, the original mark combines three ascending rounded quota slots with one open left-return track. The slots indicate independently available quota; the return track indicates switching. It uses neither the incumbent people/knot mark nor a brand initial. This is an original session-authored geometric design, not a trademark clearance claim.

The shared geometry lives in `scripts/generate-original-icons.swift`, with an editable SVG counterpart at `assets/app-icon-source.svg`. The app tile is restrained indigo with a white mark and transparent exterior. The tray is the identical mark in black alpha on a transparent canvas; `MenuBarLogo` remains a template, while the existing quota renderer applies explicit appearance-sensitive alpha tint inside its colored, non-template composite. The menu glyph is drawn at 16pt. There are no behavior or quota-threshold changes.

## Generation record

Built-in imagegen was used to establish the original visual direction. Its unedited transparent output is preserved at `assets/original-icon-concept.png`. For precise small-size rendering, the final geometry is authored natively with AppKit paths and mirrored into SVG; final PNGs are rendered directly from these paths, not edited from the generated bitmap. This keeps application and menu symbols consistent and removes raster-generation softness.

Prompt:

> Create an original macOS utility app icon, 1024x1024, isolated on transparent background. Product is a three-account token quota switcher. Restrained solid deep cobalt-indigo rounded square app tile with generous transparent exterior padding. Center a bold crisp white geometric glyph: three vertical rounded pill slots arranged horizontally with aligned bottoms, left slot shortest, middle medium, right tallest, and a simple open angular return track below that curls leftward into a short left-pointing chevron. Glyph should feel purpose-built and recognizable at 16 pixels: exactly three bars and one open return stroke, generous gaps, no fine details. Flat vector-like hard edges, no text, no letters, no people, no knots, no loops, no OpenAI/ChatGPT mark, no other existing brand. No gradients, no texture, no bevel, no floating shadow, no perspective. Keep the three ascending bars and separate return track clean and visually balanced. This is the final app asset, not a presentation board.

## Rebuild

Run `swift scripts/generate-original-icons.swift` from the repository root. The script renders all standard 16/32/128/256/512pt 1x and 2x iconset representations, packages AppIcon.icns with iconutil, then removes the intermediate iconset directory. The existing package script already copies `AppIcon.icns` and the SwiftPM resource bundle; no packaging or loading source changes were needed.

## Verification

The source PNGs preserve alpha and the ICNS includes standard representations through 1024px. Renderer fixtures cover light, dark, highlighted and cached states, including 0/9/10/49/50/100/missing. They are not live status-bar screenshots.
