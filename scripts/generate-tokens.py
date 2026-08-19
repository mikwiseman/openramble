#!/usr/bin/env python3
"""Writes the shared visual tokens into both platforms.

macOS reads Swift constants and the desktop app reads CSS custom properties, so
the same numbers have to exist twice in the built product. Typing them twice is
what makes them drift; generating them means a change to design/tokens.json
reaches both, and check.sh fails if either file no longer matches.
"""
from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKENS = ROOT / "design" / "tokens.json"
SWIFT = ROOT / "apps/macos/OpenRamble/UI/GlassTokens.swift"
CSS = ROOT / "apps/desktop/ui/tokens.css"

BANNER = "Generated from design/tokens.json by scripts/generate-tokens.py. Do not edit."


def number(value: float) -> str:
    """Whole numbers without a trailing .0, so the output reads like a value."""
    return str(int(value)) if float(value).is_integer() else str(value)


def swift(tokens: dict) -> str:
    r, s, k, t, m = (tokens[key] for key in ("radius", "space", "stroke", "type", "motion"))
    return f'''import SwiftUI

/// The visual vocabulary shared with the Windows and Linux interface.
///
/// {BANNER}
///
/// The two platforms render differently on purpose — only native code can call
/// Apple's Liquid Glass, which samples and refracts the desktop behind the
/// window — but the geometry and rhythm are one decision, made once.
enum GlassTokens {{
    /// Concentric radii: a control inside a surface takes the smaller one so
    /// their curves stay parallel rather than fighting.
    enum Radius {{
        static let surface: CGFloat = {number(r["surface"])}
        static let control: CGFloat = {number(r["control"])}
        static let chip: CGFloat = {number(r["chip"])}
    }}

    /// One spacing rhythm, so nothing is nudged by eye.
    enum Space {{
        static let tight: CGFloat = {number(s["tight"])}
        static let inline: CGFloat = {number(s["inline"])}
        static let stack: CGFloat = {number(s["stack"])}
        static let section: CGFloat = {number(s["section"])}
        static let page: CGFloat = {number(s["page"])}
    }}

    /// Weights, not colours: the colour comes from the system label, so it
    /// follows light and dark by itself.
    enum Stroke {{
        static let hairline: CGFloat = {number(k["hairline"])}
        static let emphasised: CGFloat = {number(k["emphasised"])}

        /// "Increased Contrast makes elements predominantly black or white and
        /// highlights them with a contrasting border."
        static func opacity(increasedContrast: Bool) -> Double {{
            increasedContrast ? {number(k["opacityIncreasedContrast"])} : {number(k["opacityNormal"])}
        }}
    }}

    enum Label {{
        static let sectionHeader: CGFloat = {number(t["sectionHeader"])}
        static let footnote: CGFloat = {number(t["footnote"])}
    }}

    /// Durations. Reduced Motion turns these to zero rather than shortening them.
    enum Motion {{
        static let controlFeedback: Double = {number(m["controlFeedback"])} / 1000
        static let surfaceChange: Double = {number(m["surfaceChange"])} / 1000
    }}
}}
'''


def css(tokens: dict) -> str:
    r, s, k, t, m = (tokens[key] for key in ("radius", "space", "stroke", "type", "motion"))
    return f'''/* {BANNER}
 *
 * The visual vocabulary shared with the macOS interface. The two render
 * differently on purpose — only native code can call Apple's Liquid Glass,
 * which samples and refracts the desktop behind the window — but the geometry
 * and rhythm are one decision, made once.
 */
:root {{
  --radius-surface: {number(r["surface"])}px;
  --radius-control: {number(r["control"])}px;
  --radius-chip: {number(r["chip"])}px;

  --space-tight: {number(s["tight"])}px;
  --space-inline: {number(s["inline"])}px;
  --space-stack: {number(s["stack"])}px;
  --space-section: {number(s["section"])}px;
  --space-page: {number(s["page"])}px;

  --stroke-hairline: {number(k["hairline"])}px;
  --stroke-emphasised: {number(k["emphasised"])}px;
  --stroke-opacity: {number(k["opacityNormal"])};
  --stroke-opacity-contrast: {number(k["opacityIncreasedContrast"])};

  --type-section-header: {number(t["sectionHeader"])}px;
  --type-footnote: {number(t["footnote"])}px;

  --motion-control: {number(m["controlFeedback"])}ms;
  --motion-surface: {number(m["surfaceChange"])}ms;
}}

/* "Reduced Motion decreases the intensity of some effects and disables any
   elastic properties for the material." Zero, not merely shorter. */
@media (prefers-reduced-motion: reduce) {{
  :root {{
    --motion-control: 0ms;
    --motion-surface: 0ms;
  }}
}}
'''


def main() -> int:
    tokens = json.loads(TOKENS.read_text())
    check = "--check" in sys.argv
    stale = []

    for path, rendered in ((SWIFT, swift(tokens)), (CSS, css(tokens))):
        current = path.read_text() if path.exists() else None
        if current == rendered:
            continue
        if check:
            stale.append(path.relative_to(ROOT))
        else:
            path.write_text(rendered)
            print(f"wrote {path.relative_to(ROOT)}")

    if stale:
        print("These no longer match design/tokens.json:", file=sys.stderr)
        for path in stale:
            print(f"  {path}", file=sys.stderr)
        print("Run scripts/generate-tokens.py to bring them back.", file=sys.stderr)
        return 1
    if check:
        print("Both platforms match design/tokens.json.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
