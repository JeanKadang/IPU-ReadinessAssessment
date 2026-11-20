---
name: IPU Readiness Assessment
description: Sober, evidence-first operations report for Windows Server upgrade readiness; flat bordered panels, navy masthead, status color only where it carries meaning.
colors:
  ink: "#16202e"
  muted: "#5d6a79"
  line: "#dde3ea"
  page: "#f3f5f8"
  panel: "#ffffff"
  navy: "#16365f"
  header-tint: "#eef2f7"
  header-ink: "#30475f"
  caution-bg: "#fff4d6"
  caution-ink: "#5c4400"
  caution-line: "#e6c46a"
  status-special: "#0f4c5c"
  status-blocker: "#7a1717"
  status-action: "#b42318"
  status-warning: "#9a5800"
  status-manual: "#5b47a0"
  status-ok: "#17703a"
  status-info: "#4a6578"
  dark-ink: "#e6edf5"
  dark-muted: "#a9b6c4"
  dark-line: "#2c3947"
  dark-page: "#0e141b"
  dark-panel: "#16202b"
  dark-heading: "#a9c8f0"
  dark-focus: "#8fb8ff"
typography:
  display:
    fontFamily: "'Segoe UI', Arial, sans-serif"
    fontSize: "24px"
    fontWeight: 600
    lineHeight: 1.2
  headline:
    fontFamily: "'Segoe UI', Arial, sans-serif"
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.3
  title:
    fontFamily: "'Segoe UI', Arial, sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.4
  body:
    fontFamily: "'Segoe UI', Arial, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "'Segoe UI', Arial, sans-serif"
    fontSize: "11px"
    fontWeight: 700
    letterSpacing: "0.04em"
  mono:
    fontFamily: "Consolas, 'Cascadia Mono', monospace"
    fontSize: "12px"
    lineHeight: 1.45
rounded:
  sm: "4px"
  md: "6px"
  lg: "10px"
  hero: "12px"
  pill: "999px"
spacing:
  xs: "6px"
  sm: "8px"
  md: "14px"
  lg: "20px"
  xl: "24px"
components:
  hero:
    backgroundColor: "{colors.navy}"
    textColor: "#ffffff"
    rounded: "{rounded.hero}"
    padding: "24px 28px"
  panel:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: "18px 20px"
  summary-card:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: "12px 14px"
  status-badge:
    backgroundColor: "{colors.status-action}"
    textColor: "#ffffff"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  caution-banner:
    backgroundColor: "{colors.caution-bg}"
    textColor: "{colors.caution-ink}"
    rounded: "{rounded.lg}"
    padding: "12px 16px"
  table-header:
    backgroundColor: "{colors.header-tint}"
    textColor: "{colors.header-ink}"
    padding: "8px"
  command-box:
    backgroundColor: "{colors.header-tint}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "4px 6px"
---

# Design System: IPU Readiness Assessment

## Overview

**Creative North Star: "The Field Report"**

The report reads like a field engineer's inspection document: a navy masthead states what was inspected and the verdict, then white bordered panels hold the evidence. It is a single self-contained HTML file with no external assets, so it opens offline, survives email, and prints to PDF. The per-server report and the fleet overview share one token set and one look.

Voice is dense but scannable and corporate neutral. Information per screen is high (cards, tables, small uppercase column heads), but hierarchy is kept by size, weight and hairlines, not decoration. Color is rationed: neutrals for structure, status colors only for status. Nothing animates and nothing is ornamental.

**Key Characteristics:**
- Flat, bordered, tonal; no shadows
- Navy masthead, white panels on a pale page; full dark theme via `prefers-color-scheme`
- Status carried by a labelled pill, never by color alone
- Native system font stack; no web fonts
- Print is a first-class theme: white page, tables shrink, link URLs spelled out

## Colors

A cool slate-and-navy neutral palette with seven semantically fixed status colors.

### Primary
- **Inspection Navy** (#16365f): masthead background, headings and focus ring in light theme. Becomes **Dusk Blue** (#a9c8f0) for headings and **Signal Blue** (#8fb8ff) for focus in dark theme.

### Neutral
- **Ink Slate** (#16202e): body text. **Quiet Slate** (#5d6a79): secondary text, labels.
- **Pale Paper** (#f3f5f8): page. **Panel White** (#ffffff): all panels and cards. **Hairline** (#dde3ea): every border and row rule.
- **Header Tint** (#eef2f7) with **Header Ink** (#30475f): table headers and command boxes.
- Dark theme: page #0e141b, panel #16202b, line #2c3947, ink #e6edf5, muted #a9b6c4.

### Status
- **Special Teal** (#0f4c5c) cluster nodes / domain controllers. **Blocker Oxblood** (#7a1717) stops the upgrade. **Action Red** (#b42318) must fix. **Warning Amber** (#9a5800) review. **Manual Violet** (#5b47a0) a check errored or needs a human. **OK Green** (#17703a). **Info Slate** (#4a6578).
- **Caution Cream** (#fff4d6 / ink #5c4400 / line #e6c46a): partial-report and incomplete-coverage banners.

### Named Rules
**The Status-Is-Labelled Rule.** A status color always travels with its text label in a pill. Color alone never carries severity.
**The Contrast-Is-Tested Rule.** Text meets 4.5:1 and the focus outline 3:1 in both themes; the tests enforce it. New colors must pass before they ship.
**The Honest-Manual Rule.** An errored check is shown as Manual Violet, never as OK Green.

## Typography

**Display / Body Font:** Segoe UI (with Arial, sans-serif). **Mono:** Consolas / Cascadia Mono.

**Character:** Plain Windows-native sans, matching the audience's own tools; mono only for commands and values.

### Hierarchy
- **Display** (600, 24px, ~1.2): masthead title.
- **Headline** (600, 18px): section headings, in heading color.
- **Title** (600, 16px): collapsible `summary` rows and the verdict line.
- **Body** (400, 14px, 1.5): everything else. Summary-card figures are 24px / 650.
- **Label** (700, 11px, +0.04em, uppercase): table headers, card captions, badges, check tags.
- **Mono** (12px, 1.45): command boxes with a Copy button.

### Named Rules
**The System-Font Rule.** No web fonts, ever: the file must be self-contained.

## Layout

Centered `.wrap`, max-width 1440px, 24px/16px padding. Summary cards in a 6-column grid (2 columns under 900px). Facts in a 2-column grid (1 under 900px). Tables are min-width 860px inside a horizontal scroller. Rhythm is 6/8/14/20/24px; panels stack with 14px gaps. Print drops the max-width and padding, disables the scroller, shrinks tables to 10px, and avoids breaking inside `details`.

## Elevation & Depth

Flat. No shadows anywhere. Depth is tonal: page, then panel, then header tint, separated by 1px hairlines. Hover on a linked card changes its border to the heading color; keyboard focus uses a 3px outline with 2px offset.

### Named Rules
**The Flat-By-Default Rule.** Do not add shadows; use a border or a tint step instead.

## Shapes

Gently rounded: 10px on panels and cards, 12px on the masthead, 6px on small controls and code boxes, 4px on check tags, fully round pills for status badges. Notes (Info Slate) and special sections (Special Teal) take a full 1px border in their color; never a one-sided bar.

## Components

### Masthead (hero)
Navy block, 12px radius, white title, soft-blue supporting lines (#d5e1ee), verdict line with a status badge.

### Panels and details
White, 1px hairline, 10px radius; `details` use a 16px bold summary in heading color, clickable across the whole row.

### Summary cards
Label caption above, large figure; when a link, a trailing arrow and border-color hover.

### Status badge
Pill, white bold 11px text on the status color. The only place status colors fill a surface.

### Banners and notes
Caution Cream with 1px line for partial or incomplete reports; neutral panel with a left Info rule for "not run by choice".

### Tables
Header Tint column heads (11px uppercase), 8px cell padding, hairline row rules.

### Command box and Copy button
Mono text in a tinted bordered box; Copy appears only when JavaScript runs.

## Do's and Don'ts

### Do:
- **Do** lead with the verdict in the masthead and put the worst items first.
- **Do** pair every status color with its text label.
- **Do** keep the file single and self-contained: inline CSS, no external requests.
- **Do** verify light, dark and print themes, and keep the contrast tests green.
- **Do** edit the parts in `src/assessment/` and `src/merge/` and rebuild; never edit built scripts.

### Don't:
- **Don't** add shadows, gradients, animation or decorative imagery.
- **Don't** introduce web fonts, icon fonts or external assets.
- **Don't** show an errored check as OK.
- **Don't** convey state by color alone.
