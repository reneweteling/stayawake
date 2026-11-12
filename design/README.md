# StayAwake design

Open `contact-sheet.png` (or `contact-sheet.html` via a local server) for everything at a glance.

## Direction: night watch

An amber crescent moon inside a safety gauge ring, on the same deep ink squircle as TidyDrive. The moon says "awake at night", the ring says "measured, with limits". The ring, ticks, white end knob and ink tile echo TidyDrive's disk gauge, so the two icons read as one family. TidyDrive owns vermilion; StayAwake leads with amber and keeps vermilion as the hot end of the ring.

Imagery is cinematic night: dark ink-teal scenes lit by a warm amber glow, with small frosted-glass status chips (temperature, battery, time) and mint green for "safe".

## Palette

| Role | Hex |
|---|---|
| Ink night (page bg, dark) | `#0a1011` |
| Ink (hero bg) | `#0d1517` |
| Ink teal (icon top, surfaces) | `#1c2e32` |
| Slate track | `#3a4a4d` |
| Amber, primary accent | `#ffb547` |
| Vermilion, hot end / warnings | `#ff5a36` |
| Mint, safe state | `#5fd39a` |
| Paper (light bg, text on dark) | `#f3f5f2` |
| Muted text on dark | `#8fa0a5` |

## Type

Same stack as the TidyDrive site, so the sites match:

- Display: `"Avenir Next Condensed", "Helvetica Neue", "Arial Narrow", Arial, sans-serif`, weight 800, uppercase, `letter-spacing: -0.02em`
- Body: `"Avenir Next", "Helvetica Neue", Helvetica, Arial, sans-serif`
- Kicker / labels: `ui-monospace, "SF Mono", Menlo, monospace`, 600, uppercase, wide tracking, amber

## Files and where they go

| File | Use |
|---|---|
| `icon/icon-1024.png` | Master app icon, Big Sur grid (shape inset 9.8%, corner radius 22.5%, drop shadow) |
| `icon/AppIcon.iconset/` | All 10 iconset sizes; 16, 16@2x and 32 use the simplified glyph |
| `icon/AppIcon.icns` | Copy into `StayAwake.app/Contents/Resources/` |
| `icon/icon-small-glyph-512.png` | Simplified glyph (no ticks or star) used for the tiny sizes |
| `icon/candidates/` | All generated candidates; `icon-a2-moon-gauge-bold.png` is the source art |
| `web/hero-2400.webp`, `web/hero-1600.webp` | Site hero, use as `srcset`. Subject sits right, left half is free for the headline |
| `web/hero-alt-1600.webp` | Alternate hero (night train), not in use |
| `web/feature-safety.webp` | Safety limits section (temperature, battery floor, time cap) |
| `web/feature-schedule.webp` | Weekly schedule section |
| `web/feature-unplug.webp` | Unplug alert section |
| `web/feature-failsafe.webp` | Fail-safe section |
| `web/og.png` | Open Graph / Twitter card, 1200x630 |
| `favicon/favicon.svg` | Primary favicon (`<link rel="icon" type="image/svg+xml">`) |
| `favicon/favicon.ico` | 16/32/48 fallback |
| `favicon/favicon-16.png`, `favicon-32.png` | PNG fallbacks |
| `favicon/apple-touch-icon.png` | 180x180, full bleed (iOS rounds it) |
| `favicon/icon-192.png`, `icon-512.png` | Web manifest icons |
| `source/build_icon.py` | Rebuilds master, iconset and icns from the source art |
| `source/og.html` | OG card template, screenshot at 1200x630 |
| `source/raw/` | Full-res generations (2560x1440 hero, 2224x1664 features), webp q92 |
| `source/prompts/` | Exact prompt per image |

## Rebuild

```sh
python3 design/source/build_icon.py           # icon-1024.png, iconset, AppIcon.icns
cwebp -q 82 -resize 2400 0 <raw> -o web/hero-2400.webp
cwebp -q 80 -resize 1200 0 <raw> -o web/feature-<name>.webp
```

For the OG card, serve `design/` over http, open `source/og.html` at a 1200x630 viewport and screenshot it.

When the app build moves to this icon, `scripts/build.sh` can copy `design/icon/AppIcon.icns` instead of drawing one, or `build_icon.py` can be ported into a `make-icon.swift` like TidyDrive's.

## Generation

All images: WaveSpeed, model `openai/gpt-image-2.6-flare/text-to-image`, `quality: high`, `resolution: 2k`, `output_format: png`. Icons `aspect_ratio: 1:1`, hero `16:9`, features `4:3`. The full prompt per image is in `source/prompts/<name>.txt`. Short version:

| Image | Prompt file | Gist |
|---|---|---|
| Icon (picked) | `icon-a2-moon-gauge-bold.txt` | Thick ring gauge, 70% vermilion to amber with white knob, amber crescent moon inside, small star, five ticks |
| Icon candidates | `icon-a`, `a3`, `b`, `c`, `d`, `e` | Moon gauge, clean ring, awake eye, laptop with shield, coffee cup steam moon, moon with thermometer |
| Hero | `hero-2.txt` | Closed laptop in a backpack on a cafe table at night, amber lid glow, hovering gauge ring with moon, CPU and battery chips, phone hotspot |
| Hero alt | `hero-1.txt` | Backpack on a night train seat, glowing lid seam, 52°C / 71% / Awake 2h 14m chips |
| Safety | `feature-safety.txt` | Three glass ring dials: temperature, battery floor, time cap, linked to a moon |
| Schedule | `feature-schedule.txt` | Glass weekly calendar, night blocks glowing amber, moon rising |
| Unplug | `feature-unplug.txt` | USB-C cable pulled from a closed laptop, card "Unplugged. Stay awake?" |
| Fail-safe | `feature-failsafe.txt` | Closed laptop under a mint shield dome, heat and empty battery kept outside |

Every prompt ends with a shared style block (ink-teal night palette, amber main light, vermilion and mint accents, cinematic stylized 3D, no people, no logos), so new images stay consistent. Reuse it as is.
