# Redesign: Linear's layout, Queen Bee's colours

Mockups: https://claude.ai/artifact/W9DjJgn2afTbXEvQi282Ne (Mac flow canvas, runs, ⌘K menu, orchestrator;
iPhone needs-you, opened tab bar, flow run, approval sheet, orchestrator, agent terminal).

## What changes and what doesn't

- **Changes:** layout, navigation, surfaces, type, spacing, corners, and the frame around every card and panel.
  Linear's inverted-L window (sidebar and top strip on the darkest colour, content in an inset rounded panel),
  its sidebar, view headers with pill tabs, grouped lists, ⌘K menu, and on iPhone a floating tab bar that opens
  into a menu.
- **Stays:** Queen Bee's colours (navy surfaces, ink, orange live, green passed, red stopped, cobalt selected),
  both light and dark (new installs still follow the system), and every agent card and the orchestrator as a live
  SwiftTerm terminal running Claude Code. Behaviour is out of scope except where noted.
- **Decided:** Runs, Schedules and Devices become places in the sidebar, and runs get short IDs (RUN-48).
  The iPhone flow screen keeps opening on the canvas.

## Design system first

One module, `QueenBeeDesign` (in the `Core` package), is the only place that says how anything looks, for the Mac
and the iPhone and iPad alike. Today each app keeps its own `Tokens.swift` and copies values by hand.

- **Palette:** colour roles as light and dark pairs. Surfaces as a ladder (chrome → panel → raised → overlay, with
  hover and selected), two hairline strengths, three text strengths, the accent, the three states each as a dot,
  a tint and a text colour, the terminal, and the canvas dots.
- **Type:** roles (large title, title, headline, body, label, caption, section header, mono, mono caption) with a
  size, weight and tracking for the desk and for touch.
- **Space, radius, stroke, size, motion:** one scale each.
- **Parts:** buttons (primary, secondary, ghost, danger, live), status dot and pill, section header, key hint,
  inset panel, divider, pill tabs and the sidebar row. Screens arrange these and set no colour or size of their own.
- **Checked by tests:** every text colour meets 4.5:1 on every surface it can sit on, in both modes; faint text,
  dots and the accent meet 3:1; text on the accent meets 4.5:1.

During the move, the old token names (`Theme.paper`, `Theme.ink`…) read their values from the module's `Classic`
set, so both apps share one source at once and nothing looks different until a screen moves over. Once the last
screen has moved, `Classic` is deleted.

## Steps

1. **Design system module.** `QueenBeeDesign`: palette, type, scales, parts, contrast tests. Mac and iOS `Theme`
   read from it. No visible change. *(this branch)*
2. **Mac window frame.** Sidebar on chrome (switcher, search, new flow, Needs you / Runs / Schedules / Devices,
   Pinned, projects), content in the inset panel, breadcrumb header with Run/Stop and the branch chip, pill tabs
   (Canvas · Runs · Schedule · Settings).
3. **Mac canvas and cards.** New card frame (title bar, state, model and cost, ports) around the same terminal;
   logic cards; links; zoom pill; the terminal's colours from the palette.
4. **Mac panels.** Side panel (Orchestrator · Log · Output), inspector as a properties list, Flow Settings,
   palette, ⌘K menu, workplace popover, onboarding, Settings window, menu bar menu.
5. **Mac places.** Needs you, Runs (grouped list, run IDs, peek panel), Schedules, Devices.
6. **iPhone and iPad.** Floating tab bar and its menu, Needs you, flow list, canvas with run bar, sheets
   (details, approval), orchestrator and full-screen terminal with the Keys bar, pairing, settings. iPad keeps the
   split view in the new frame.
7. **Clean-up.** Delete `Classic` and anything no screen uses; screenshots for the README.

Each step: unit tests (`cd Core && swift test`), `./scripts/build.sh`, the iOS build, and a look at every screen
it touched in light and dark on the Mac and in one Simulator.
