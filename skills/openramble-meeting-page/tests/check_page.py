#!/usr/bin/env python3
"""Check rendered meeting pages in a real headless Chrome (development only).

    python3 tests/check_page.py PAGE.html... [--shots DIR] [--search WORD]

Needs Python Playwright and Google Chrome (channel "chrome"). For every page, at
1440x900 and 390x844, light and dark: requests on load, console messages and
errors, sideways scroll, a screenshot of the first screen, and text contrast
(WCAG AA) over the whole page with every fold open. Then, once per page: evidence opening in place, a strip tick opening its
item, search (with glossary spellings), browser find seeing transcript text,
a chapter chosen on a phone landing below the sticky search bar, the desktop
chapter list keeping the current chapter in sight, the page with JavaScript
off, and an A4 PDF with the transcript in it.
Prints a JSON report, which names elements but never quotes the meeting, and
exits 1 when a check fails. Screenshots and the PDF are kept only in --shots.
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

CONTRAST = r"""() => {
  const rgb = s => { const m = s.match(/rgba?\(([^)]+)\)/); if (!m) return null;
    const p = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number); return {r:p[0], g:p[1], b:p[2], a: p.length > 3 ? p[3] : 1}; };
  const lum = c => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b); };
  const bgOf = e => { const layers = []; while (e) { const c = rgb(getComputedStyle(e).backgroundColor);
      if (c && c.a > 0) { layers.push(c); if (c.a >= 1) break; } e = e.parentElement; }
    let base = layers.length && layers[layers.length - 1].a >= 1 ? layers.pop() : {r:255, g:255, b:255};
    for (let i = layers.length - 1; i >= 0; i--) { const l = layers[i];
      base = {r: l.r * l.a + base.r * (1 - l.a), g: l.g * l.a + base.g * (1 - l.a), b: l.b * l.a + base.b * (1 - l.a)}; }
    return base; };
  const bad = [], seen = new Set(); let n = 0;
  for (const e of document.querySelectorAll('body *')) {
    if (![...e.childNodes].some(t => t.nodeType === 3 && t.textContent.trim())) continue;
    const r = e.getBoundingClientRect(); if (!r.width || !r.height) continue;
    const s = getComputedStyle(e); if (s.visibility === 'hidden' || +s.opacity === 0) continue;
    if (e.closest('[aria-hidden=true]') || e.closest('.sr')) continue;
    let c = rgb(s.color); const b = bgOf(e);
    if (c.a < 1) c = {r: c.r * c.a + b.r * (1 - c.a), g: c.g * c.a + b.g * (1 - c.a), b: c.b * c.a + b.b * (1 - c.a)};
    const L1 = lum(c), L2 = lum(b), cr = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
    const fs = parseFloat(s.fontSize), fw = +s.fontWeight, large = fs >= 24 || (fs >= 18.66 && fw >= 700);
    n++;
    // where, never what: the text may be the meeting's
    if (cr < (large ? 3 : 4.5)) { const k = e.className + s.color; if (!seen.has(k)) { seen.add(k);
      bad.push(`${cr.toFixed(2)} ${e.tagName}.${e.className}${e.id ? '#' + e.id : ''} ${s.color}`); } }
  }
  return {checked: n, bad};
}"""


NAV_PHONE = """() => { const sel = document.querySelector('#chsel'), bar = document.querySelector('.tx-search');
  if (!sel || !sel.options.length) return null;
  const out = [];
  for (const o of [sel.options[Math.floor(sel.options.length / 2)], sel.options[sel.options.length - 1]]) {
    sel.value = o.value; sel.dispatchEvent(new Event('change'));
    out.push(Math.round(document.getElementById(o.value).getBoundingClientRect().top - bar.getBoundingClientRect().bottom));
  }
  return out; }"""

NAV_SIDE = """() => { const heads = [...document.querySelectorAll('.tx-body .chh')], side = document.querySelector('.tx-side');
  if (!heads.length) return null;
  const last = heads[heads.length - 1];
  scrollTo(0, last.getBoundingClientRect().top + scrollY - 60);
  return new Promise(res => requestAnimationFrame(() => requestAnimationFrame(() => {
    const a = document.querySelector('.tx-ch a.on'), r = a && a.getBoundingClientRect(), q = side.getBoundingClientRect();
    res({current: !!a && a.dataset.ch === last.id, inSight: !!a && r.top >= Math.max(q.top, 0) && r.bottom <= Math.min(q.bottom, innerHeight)});
  }))); }"""


def check(pages, shots, word):
    report, failed = {}, []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        for page_path in pages:
            url = Path(page_path).resolve().as_uri()
            name = Path(page_path).stem
            r = report[name] = {}
            for vw, vh, tag in ((1440, 900, "desktop"), (390, 844, "phone")):
                for scheme in ("light", "dark"):
                    ctx = browser.new_context(viewport={"width": vw, "height": vh}, color_scheme=scheme,
                                              device_scale_factor=1, is_mobile=tag == "phone", has_touch=tag == "phone")
                    pg = ctx.new_page()
                    reqs, cons, errs = [], [], []
                    pg.on("request", lambda q: reqs.append(q.url))
                    pg.on("console", lambda m: cons.append(f"{m.type}: {m.text}"))
                    pg.on("pageerror", lambda e: errs.append(str(e)))
                    t0 = time.time()
                    pg.goto(url, wait_until="load")
                    load_ms = round((time.time() - t0) * 1000)
                    pg.wait_for_timeout(250)
                    info = pg.evaluate("() => ({sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth,"
                                       " h: document.documentElement.scrollHeight})")
                    if shots:
                        pg.screenshot(path=str(Path(shots) / f"{name}-{tag}-{scheme}.png"))
                    pg.evaluate("() => document.querySelectorAll('details').forEach(d => { d.open = true; })")
                    contrast = pg.evaluate(CONTRAST)
                    k = f"{tag}-{scheme}"
                    r[k] = {"requests": len(reqs) - 1, "console": cons, "errors": errs, "sideways": info["sw"] - info["cw"],
                            "height": info["h"], "loadMs": load_ms, "contrastBad": contrast["bad"]}
                    if len(reqs) != 1 or cons or errs or info["sw"] > info["cw"] or contrast["bad"]:
                        failed.append(f"{name} {k}")
                    ctx.close()
            ctx = browser.new_context(viewport={"width": 1440, "height": 900})
            pg = ctx.new_page()
            errs = []
            pg.on("pageerror", lambda e: errs.append(str(e)))
            pg.goto(url)
            y0 = pg.evaluate("scrollY")
            pg.locator(".lead a.ts").first.click()
            r["evidenceInPlace"] = pg.evaluate("() => ({panel: !!document.querySelector('.lead .evp li'), y: scrollY})")
            r["evidenceInPlace"]["moved"] = r["evidenceInPlace"]["y"] - y0
            tick = pg.locator(".sl a.tk").first
            if tick.count():
                tick.click(force=True)
                pg.wait_for_timeout(200)
                r["tickOpensItem"] = pg.evaluate("() => !!document.querySelector('details.it[open]')")
            if word:
                t0 = time.time()
                pg.fill("#q", word)
                pg.wait_for_timeout(400)
                r["search"] = {"word": word, "hits": pg.locator("mark").count(), "status": pg.inner_text("#hits")}
                t1 = time.time()
                r["searchMs"] = pg.evaluate("""(w) => { const q = document.querySelector('#q'); q.value = '';
                    q.dispatchEvent(new Event('input')); return new Promise(res => setTimeout(() => {
                    const t = performance.now(); q.value = w; q.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter'}));
                    res(Math.round(performance.now() - t)); }, 200)); }""", word)
            sample = pg.evaluate("() => { const s = [...document.querySelectorAll('.tx-body .sg')].filter(x => !x.closest('.silent')); "
                                 "return s.length ? s[s.length - 1].textContent.split(' ').slice(0, 3).join(' ') : ''; }")
            pg.evaluate("() => { const q = document.querySelector('#q'); if (q) { q.value = ''; q.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'})); } }")
            r["browserFind"] = pg.evaluate("(t) => { getSelection().removeAllRanges(); scrollTo(0, 0); return window.find(t); }", sample)
            # the PDF holds the whole meeting: kept only in --shots, otherwise made and deleted in a private temp folder
            with tempfile.TemporaryDirectory() as tmp:
                pdf = Path(shots or tmp) / f"{name}.pdf"
                pg.pdf(path=str(pdf), format="A4", print_background=True, prefer_css_page_size=True)
                os.chmod(pdf, 0o600)
                data = pdf.read_bytes()
            r["pdfPages"] = len(re.findall(rb"/Type\s*/Page[^s]", data))
            r["pageErrors"] = errs
            r["sidebar"] = pg.evaluate(NAV_SIDE)
            ctx.close()
            ctx = browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
            pg = ctx.new_page()
            pg.goto(url)
            pg.evaluate("document.getElementById('transcript').scrollIntoView()")
            r["chapterBelowBar"] = pg.evaluate(NAV_PHONE)
            ctx.close()
            ctx = browser.new_context(viewport={"width": 1440, "height": 900}, java_script_enabled=False)
            pg = ctx.new_page()
            pg.goto(url)
            html_text = Path(page_path).read_text(encoding="utf-8")
            r["noJs"] = {"segmentsInHtml": len(re.findall(r'class="sg[^"]*" id="s\d+"', html_text)),
                         "foldsWork": pg.locator("details.it").count() > 0}
            if shots:
                pg.screenshot(path=str(Path(shots) / f"{name}-nojs.png"))
            ctx.close()
            if not r["evidenceInPlace"]["panel"] or abs(r["evidenceInPlace"]["moved"]) > 2 or errs or not r["browserFind"]:
                failed.append(f"{name} interactions")
            if (r["chapterBelowBar"] and min(r["chapterBelowBar"]) < 0) or (r["sidebar"] and not all(r["sidebar"].values())):
                failed.append(f"{name} navigation")
        browser.close()
    report["failed"] = failed
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pages", nargs="+")
    ap.add_argument("--shots")
    ap.add_argument("--search", default="")
    a = ap.parse_args()
    if a.shots:
        Path(a.shots).mkdir(parents=True, exist_ok=True)
    report = check(a.pages, a.shots, a.search)
    print(json.dumps(report, ensure_ascii=False, indent=1))
    return 1 if report["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
