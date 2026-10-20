---
version: alpha
name: Addon Forge starter look
description: >-
  The default look that `forge new` gives a WoW 3.3.5a addon, plus the
  readability rules every addon built with Forge must keep. Each addon may
  change the look (NFR-1.10); it may not break the rules in Do's and Don'ts.
colors:
  primary: "#ffd100"
  on-primary: "#000000"
  surface: "#05080f"
  text-highlight: "#ffffff"
  text-disabled: "#808080"
  error: "#ff1a1a"
  success: "#1aff1a"
typography:
  title:
    fontFamily: Friz Quadrata
    fontSize: 16px
  body:
    fontFamily: Friz Quadrata
    fontSize: 12px
  body-small:
    fontFamily: Friz Quadrata
    fontSize: 10px
  input:
    fontFamily: Arial Narrow
    fontSize: 14px
rounded:
  none: 0px
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
components:
  window:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.body}"
    rounded: "{rounded.none}"
    padding: 12px
  window-title:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.title}"
  list-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-highlight}"
    typography: "{typography.body-small}"
    height: 18px
  list-row-disabled:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-disabled}"
    typography: "{typography.body-small}"
    height: 18px
  button:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.body-small}"
    height: 22px
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.body-small}"
    height: 22px
  edit-box:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-highlight}"
    typography: "{typography.input}"
    padding: 4px
  status-error:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.error}"
    typography: "{typography.body}"
  status-success:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.success}"
    typography: "{typography.body}"
---

# Addon Forge starter look

## Overview

This file owns the visual and interaction rules for addons built with Forge
in the WoW 3.3.5a (build 12340) client. Forge itself has no graphical UI; its
offline checks enforce these rules (`forge.layoutIssues`, `forge.sketch`,
REQUIREMENTS.md FR-4.7, FR-4.8).

The tokens describe the **starter look** that `forge new` writes (FR-1.1):
a dark, nearly opaque panel with gold text in the client's own fonts, so a
new addon looks at home next to Blizzard frames. An addon MAY replace any
token (decided 2026-10-20: each addon its own look). The rules in
[Do's and Don'ts](#dos-and-donts) apply to every addon.

Users: raid members and raid leads on German (deDE) and English (enUS)
clients (NFR-1.9), often with a full 25-player raid on screen.

## Colors

Colors are WoW color values (0-1 per channel) written as hex. Contrast is
measured against `surface` (the starter backdrop, 0.02/0.03/0.06 at 95%
opacity):

| Token | Client meaning | Contrast on `surface` |
|---|---|---|
| `primary` | `GameFontNormal` gold (1, 0.82, 0): titles, labels, buttons | 13.7:1 |
| `text-highlight` | `GameFontHighlight` white: values, list rows | 20.0:1 |
| `text-disabled` | `GameFontDisable` gray (0.5): inactive rows and buttons | 5.1:1 |
| `error` | `RED_FONT_COLOR` (1, 0.1, 0.1) | 5.2:1 |
| `success` | `GREEN_FONT_COLOR` (0.1, 1, 0.1) | 14.7:1 |
| `on-primary` | black text on a gold primary button | 14.4:1 |

**Client-defined data colors.** The client colors item links by quality and
players by class. Addons show these colors unchanged so that players can
recognize them. On `surface`, three of them are below 4.5:1: rare items and
Shaman (0, 0.44, 0.87; 4.2:1), epic items (0.64, 0.21, 0.93; 4.1:1), and Death
Knight (0.77, 0.12, 0.23; 3.4:1). They stay as the client shows them: a
documented exception to the 4.5:1 rule (DQ-1). No dark background can fix
them (pure black gives at most 3.6-4.4:1), and a light one hides the gold and
white text.

Never show meaning by color alone: a status also needs a word or an icon
(for example "MS"/"OS", "passed").

## Typography

The client draws text with font objects. Each token names the font object
that an addon uses for it:

| Token | Font object | Use |
|---|---|---|
| `title` | `GameFontNormalLarge` | Window titles |
| `body` | `GameFontNormal` / `GameFontHighlight` | Labels, status lines |
| `body-small` | `GameFontNormalSmall` | Lists, buttons, dense tables |
| `input` | `ChatFontNormal` | Edit boxes for import and export |

`ASSUMPTION`: the sizes (16, 12, 10, 14) are the stock enUS and deDE client
defaults. `forge api dump` will record the real font object sizes, and the
offline layout will use them (DQ-2, REQUIREMENTS.md FR-3.6). Offline layout
estimates text widths (0.6 em per character, FR-4.7), so text that is close
to its limit needs a live screenshot.

The 3.3.5a `Button` has no text color, justify or inset methods. A button's
text is styled through its own font string. `FontString:SetWordWrap(false)`
cuts long single-line text; `SetMaxLines` does not exist.

## Layout

- The smallest supported screen is 1280 x 720 at UI scale 1 (the offline
  `UIParent`). A window MUST fit on it completely: `forge.layoutIssues(UIParent)`
  reports a window that sticks out (DQ-4). Larger UI scales are not required.
- Spacing uses the `spacing` scale (4, 8, 12, 16). The starter backdrop has a
  3 px inset and a 12 px edge; content starts inside the inset.
- List rows are 18 px high. A list that can hold more rows than it shows
  scrolls with the mouse wheel; RaidWishlist shows 17 rows.
- Lay windows out for real data: 25 raiders, long German player, item and
  creature names, and many items. Specs set that data up and run
  `forge.layoutIssues` and `forge.sketch` on it (FR-4.7, FR-4.8).
- When a region is removed or resized, re-anchor its neighbours so that no
  gap stays behind.
- A window can be moved by dragging and toggled by its slash command (the
  starter look does both).

## Elevation & Depth

- Normal windows use the `MEDIUM` or `DIALOG` strata, call
  `SetToplevel(true)` and raise themselves when shown, because two addon
  windows in the same strata draw through each other.
- Popups that must stay visible (roll prompts, confirmations) use
  `FULLSCREEN_DIALOG`.
- A popup in Blizzard's `StaticPopup` system can land in any slot: find it by
  its name, never by slot number.
- Opaque panels use `Interface\ChatFrame\ChatFrameBackground`; the tooltip
  background texture is translucent.

## Shapes

`rounded: none`. WoW frames get their outline from a backdrop border texture
(the starter look uses the tooltip border with a 12 px edge), not from a
corner radius. Icons are square item or spell textures.

## Components

- **window**: backdrop panel, `title` at the top, content inside a 12 px
  padding. Movable.
- **list-row**: one entity per row (player, item, roll). The name is on the
  left, values are on the right; a long name is cut, never wrapped over the
  next row.
- **button**: gold text on the panel. `button-primary` (black on gold) is for
  the one main action in a view.
- **edit-box**: for import and export strings. It drops focus after use so
  that typed chat is not swallowed.
- **tabs**: one row of buttons at the top of the window; the active tab is
  marked by more than color.
- **status line**: `status-error` or `status-success` text that also says the
  outcome in words.
- **tooltip**: a short explanation on mouse-over. Required on every control
  whose label does not explain it (icons, abbreviations such as "MS", "OS",
  "DE"); optional on clear ones such as "Close" (DQ-3). RaidLedger has one on
  every control, which is allowed.
- **minimap button**: optional; drag moves it around the minimap.

## Do's and Don'ts

**Do**

- Keep every visible region inside its parent and free of overlaps:
  `forge.layoutIssues(frame)` returns nothing for a window filled with
  realistic data.
- Make a `forge.sketch` of each window with full data and compare it with a
  live screenshot before calling the UI done.
- Fit both deDE and enUS text; plan for the longer German string.
- Ask for confirmation before an action that clears or overwrites data (for
  example "new raid" or "clear").
- Start an action that the client protects (for example `CalendarAddEvent`)
  from a real click on a visible button, with a second explicit click when
  the first click only prepares it.
- Show item links and class colors exactly as the client does.

**Don't**

- Don't use APIs, methods or templates from later expansions; check them with
  `forge api lookup`.
- Don't show color as the only signal.
- Don't let text wrap into the next row or out of the window.
- Don't put `|` into strings that players paste or that addons exchange;
  `|` starts client escape codes (texture, color and link). RaidLedger
  formats use `;` for this reason. The rules for showing text that other
  players send are security controls and belong in `SECURITY.md`.
- Don't leave an edit box holding keyboard focus after its action.
- Don't rely on `StaticPopup1`; look popups up by name.

## Open Questions

None. Answered on 2026-10-20:

- **DQ-1** Answered: rare/epic item colors and Shaman/Death Knight class
  colors stay as the client shows them, as a documented contrast exception.
- **DQ-2** Answered: `forge api dump` records the real font object sizes
  (REQUIREMENTS.md FR-3.6).
- **DQ-3** Answered: tooltips are required only where a label does not explain
  the control.
- **DQ-4** Answered: windows must fit on 1280 x 720 at UI scale 1.
