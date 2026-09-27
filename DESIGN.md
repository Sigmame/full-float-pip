# VibeFloat design system

VibeFloat keeps a video visible while someone works. Its controls should be easy to find, easy to read, and quiet when idle. This document is the source of truth for the Chrome popup, the movie catalog, and the macOS floating player.

## Color

Use semantic roles rather than adding a new hue for each feature. Both web surfaces use a dark theme; native controls sit over video and use translucent dark chrome. Never use color alone to communicate state.

| Role | Web value | Use |
| --- | --- | --- |
| Canvas | `#121216` | Page background |
| Surface | `#1c1c24` | Navigation, cards, dialogs |
| Raised surface | `#282834` | Hovered cards and inputs |
| Primary text | `#f5f5f7` | Headings, body, controls |
| Secondary text | `#c4c4ce` | Supporting text |
| Muted text | `#a1a1ae` | Metadata on a dark surface |
| Accent | `#ff3b5c` | Selected state, progress, primary action |
| Accent hover | `#ff5274` | Hover on accent actions |
| Focus | `#ff8da0` | Keyboard focus indicator |
| Success | `#34d399` | Completed action or connected state |
| Warning | `#fbbf24` | Action needed or degraded state |
| Error | `#fb7185` | Failed action and field error |
| Stroke | `rgba(255,255,255,.14)` | Control boundaries |

Primary body text aims for at least 4.5:1 contrast. Small badges need 4.5:1 too; choose a dark foreground on bright colors. Icons and large text need at least 3:1. Use `#17171d` text on white or other bright primary buttons. The catalog may display colored movie artwork and editorial badges, but those colors do not become control accents.

## Type and spacing

Use the system font stack: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif`. Use a clear hierarchy: display 28–36 px, page title 21–24 px, section title 18–20 px, body 14–16 px, supporting text 12–13 px. Interactive text stays at least 13 px in the catalog and 11 px in the compact desktop popup. Line height is 1.4–1.6 for prose and at least 1.2 for short labels. Avoid fixed-height text containers that clip at browser zoom.

Space follows a 4 px grid: 4, 8, 12, 16, 24, 32, and 48 px. Use 4–8 px inside compact controls, 12–16 px between related controls, and 24–32 px between content groups. A one-pixel rule is allowed for borders. The native player uses the equivalent 4-point grid.

## Shape and components

Use 6 px radius for small controls, 10 px for cards and inputs, 14 px for dialogs, and a full pill only for category chips. Native AppKit controls use the existing 7/9/14 pt radius scale where platform rendering requires it. Controls of the same role use the same padding, height, type weight, radius, and states across their surface.

Primary buttons use the accent or a high-contrast light fill, secondary buttons use a raised surface and stroke, and quiet buttons use a transparent fill. Every button has visible hover, pressed, keyboard focus, and disabled states. Loading actions announce progress and prevent duplicate submission. Cards use one surface and one hover treatment. Inputs have a visible label, helper or inline error text, and a focus ring. Tabs show selection with both shape and color. Destructive actions identify their effect in text.

## Responsive and motion rules

The catalog supports 320 px and wider viewports without document-level horizontal overflow. On narrow screens, secondary navigation goes into a labeled menu. Touch targets are at least 44 × 44 px. Content wraps or reflows at 200% text size; long titles may wrap or truncate with a way to see the full title. The extension popup is a desktop Chrome surface with a fixed browser-controlled width.

Use 120–200 ms transitions for hover, pressed, dropdown, and tab changes; use opacity and transform for overlays. Focus must move into open dialogs and return to their trigger when closed. Respect `prefers-reduced-motion` by removing nonessential transitions. Loading, empty, error, and success states give a clear next action. Messages about async outcomes use a live region.

Show movie ratings, quality, release year, audio type, and availability only when the source supplies them. Do not derive promotional percentages or age ratings from unrelated fields.

## Implementation map

`extension/popup.css` and `extension/catalog.css` define the web role variables at `:root`; component rules consume those variables. `native-app/Sources/FloatWindow.swift` defines the matching AppKit roles in `VibeTheme`. If a component needs a new color, type size, spacing step, or radius, add its reason and role here before adding the value in code. Movie art, source logos, platform traffic-light controls, and one-pixel hairlines are content or platform exceptions.
