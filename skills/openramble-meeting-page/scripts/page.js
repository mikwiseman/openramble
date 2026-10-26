(() => {
  'use strict';
  const d = document;
  d.documentElement.classList.remove('no-js');
  const $ = (s, r = d) => r.querySelector(s);
  const $$ = (s, r = d) => Array.from(r.querySelectorAll(s));
  const D = JSON.parse($('#data').textContent);
  const T = D.t;
  const pad = n => String(n).padStart(2, '0');
  const fmt = t => {
    t = Math.max(0, Math.floor(t));
    const h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), s = t % 60;
    return D.long ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
  };
  const segEls = $$('.tx-body .sg');
  let idIndex = null;
  const indexOf = id => {
    if (!idIndex) { idIndex = new Map(); segEls.forEach((e, i) => idIndex.set(e.id, i)); }
    return idIndex.get(id);
  };
  const label = el => D.timed ? fmt(+el.dataset.s) : '¶' + (indexOf(el.id) + 1);
  const speakerOf = el => { const t = el.closest('.turn'); return t && t.dataset.sp ? t.dataset.sp : null; };

  /* ---------- jumps, with a way back ---------- */
  const back = $('#back');
  let backY = null, lastInput = 0;
  for (const ev of ['wheel', 'touchmove', 'keydown']) addEventListener(ev, () => { lastInput = Date.now(); }, { passive: true });
  // a long transcript lays out its chunks only as they come into sight, and the browser's scroll anchoring can then
  // carry the target off its place a frame or two later: put it back while the layout settles, unless the reader moves
  let landing = 0;
  function land(el, block) {
    el.scrollIntoView({ block });
    const want = el.getBoundingClientRect().top, id = ++landing, since = lastInput;
    let n = 0;
    const check = () => {
      if (id !== landing || lastInput !== since) return;
      if (Math.abs(el.getBoundingClientRect().top - want) > 1) el.scrollIntoView({ block });
      if (++n < 12) requestAnimationFrame(check);
    };
    requestAnimationFrame(check);
  }
  function flash(el) {
    if (!el) return;
    $$('.here').forEach(x => x.classList.remove('here'));
    el.classList.remove('flash');
    void el.offsetWidth;
    el.classList.add('flash');
    setTimeout(() => el.classList.remove('flash'), 1700);
  }
  function jump(el, block) {
    if (!el) return;
    if (backY === null || Math.abs(scrollY - backY) > 4) backY = scrollY;
    land(el, block || 'center');
    back.hidden = false;
    flash(el);
  }
  back.addEventListener('click', () => { landing++; if (backY !== null) scrollTo(0, backY); backY = null; back.hidden = true; });
  function openItem(id) {
    const el = d.getElementById(id);
    if (!el) return;
    if (el.matches('details')) el.open = true;
    jump(el, el.id === 'lead' ? 'start' : 'center');
  }

  /* ---------- evidence opens in place ---------- */
  let panels = 0;
  function evRow(id, primary, many) {
    const seg = d.getElementById(id);
    if (!seg) return null;
    const li = d.createElement('li');
    li.className = 'evs' + (id === primary && many ? ' pri' : '');
    if (player) {
      const b = d.createElement('button');
      b.type = 'button'; b.className = 'pl'; b.dataset.sid = id;
      b.setAttribute('aria-label', `${T.play} ${label(seg)}`);
      li.append(b);
    }
    const a = d.createElement('a');
    a.className = 'jump'; a.href = '#' + id; a.textContent = label(seg);
    li.append(a);
    const sp = D.speakers[speakerOf(seg)];
    if (sp) { const w = d.createElement('span'); w.className = 'who ' + sp.cls; w.textContent = sp.short; li.append(w); }
    const q = d.createElement('span');
    q.className = 'eq';
    if (id === primary && many) {
      const sr = d.createElement('span'); sr.className = 'sr'; sr.textContent = `(${T.primary}) `; q.append(sr);
    }
    q.append(seg.textContent);
    li.append(q);
    return li;
  }
  function togglePanel(a) {
    const host = a.closest('[data-host]');
    const wasOpen = a.getAttribute('aria-expanded') === 'true';
    $$('a.ts[aria-expanded="true"]', host).forEach(x => x.setAttribute('aria-expanded', 'false'));
    let panel = $(':scope > .evp', host);
    if (wasOpen) { if (panel) panel.remove(); return; }
    if (!panel) { panel = d.createElement('div'); panel.className = 'evp'; panel.id = 'evp' + (++panels); host.append(panel); }
    const ids = a.dataset.ev.split(' ');
    const ol = d.createElement('ol'); ol.className = 'evl';
    ids.forEach(id => { const r = evRow(id, a.dataset.pri, ids.length > 1); if (r) ol.append(r); });
    panel.replaceChildren(ol);
    a.setAttribute('aria-expanded', 'true');
    a.setAttribute('aria-controls', panel.id);
  }

  /* ---------- audio: loaded only when asked for ---------- */
  // 'g' is one file with everyone; without it each speaker has a track, and '*' plays all tracks together
  const player = $('#player'), au = $('#au');
  const srcs = {};
  if (D.audio) srcs.g = D.audio;
  for (const k in D.speakers) if (D.speakers[k].audio) srcs[k] = D.speakers[k].audio;
  const tracks = Object.keys(srcs).filter(k => k !== 'g');
  let curKey = null, stopAt = null, follow = false, nowEl = null, want = null;
  const ph = $('#ph'), spPlay = $('#sp-play');
  const bySpeaker = {};
  const startsAll = segEls.map(e => +e.dataset.s);
  const meetingKey = () => srcs.g ? 'g' : tracks.length > 1 ? '*' : tracks[0] || null;
  const keyFor = sp => srcs.g ? 'g' : (sp && srcs[sp] ? sp : meetingKey());
  const leadKey = () => curKey === '*' ? tracks[0] : curKey;
  const mix = [];  // the other tracks, kept in step with au while '*' plays
  const lost = new Set();  // tracks whose file is not next to the page
  const sounds = e => !e.paused && !e.error;
  const playing = () => sounds(au) || (curKey === '*' && mix.some(m => sounds(m.el)));
  function segAt(t, sp) {
    let els = segEls, starts = startsAll;
    if (sp) {
      if (!bySpeaker[sp]) {
        const e = segEls.filter(x => speakerOf(x) === sp);
        bySpeaker[sp] = { els: e, starts: e.map(x => +x.dataset.s) };
      }
      ({ els, starts } = bySpeaker[sp]);
    }
    let lo = 0, hi = starts.length - 1, ans = -1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (starts[m] <= t) { ans = m; lo = m + 1; } else hi = m - 1; }
    for (let i = ans; i >= 0 && i > ans - 4; i--) {
      if (!els[i].closest('.silent') && t <= +els[i].dataset.e + 0.4) return els[i];
    }
    return null;
  }
  function showPlayer() {
    if (!player) return;
    player.hidden = false;
    d.body.classList.add('has-player');
    if (ph) ph.setAttribute('visibility', 'visible');
  }
  const inUse = k => k === leadKey() || (curKey === '*' && tracks.includes(k));
  function showLost() {
    const k = [...lost].find(inUse);
    player.classList.toggle('missing', !!k);
    $('#pmiss').hidden = !k;
    if (k) $('#pmsg').textContent = T.missing.replace('{f}', srcs[k].name);
  }
  function missing(k) {
    if (!k || !srcs[k]) return;
    lost.add(k);
    showLost();
    sync();
  }
  function joinMix() {
    for (const k of tracks.slice(1)) {
      let m = mix.find(x => x.k === k);
      if (!m) {
        m = { k, el: new Audio(), src: null };
        m.el.preload = 'none';
        m.el.addEventListener('error', () => missing(k));
        m.el.addEventListener('play', sync);
        m.el.addEventListener('pause', sync);
        mix.push(m);
      }
      if (m.src !== srcs[k].src) { m.src = srcs[k].src; m.el.src = m.src; }
    }
  }
  function mixAlong(on, t) {
    for (const m of mix) {
      if (!on) { m.el.pause(); continue; }
      if (Math.abs(m.el.currentTime - t) > 0.15) { try { m.el.currentTime = t; } catch (e) { /* not seekable yet */ } }
      m.el.play().catch(() => {});
    }
  }
  function play(t, end, key, followIt) {
    if (!player || !key) return;
    showPlayer();
    want = { t, end };
    stopAt = end == null ? null : end + 0.3;
    follow = !!followIt;
    if (key !== curKey) {
      if (curKey === '*') mixAlong(false);
      curKey = key;
      au.src = srcs[leadKey()].src;
      if (key === '*') joinMix();
      showLost();
      if (nowEl) nowEl.classList.remove('now');
      nowEl = undefined;  // the caption names a track or a speaker: write it afresh
    }
    const at = Math.max(0, t - 0.15);
    if (key === '*') mixAlong(true, at);  // started here, inside the click, where browsers allow sound
    const go = () => { try { au.currentTime = at; } catch (e) { /* not seekable yet */ } au.play().catch(() => {}); };
    if (au.readyState >= 1) go(); else { au.addEventListener('loadedmetadata', go, { once: true }); au.load(); }
  }
  function resume() {
    stopAt = null;
    au.play().catch(() => {});
    if (curKey === '*') mixAlong(true, au.currentTime);
  }
  function pause() { au.pause(); mixAlong(false); }
  function sync() {
    const on = playing();
    $('#pp').classList.toggle('paused', !on);
    $('#pp').setAttribute('aria-label', on ? T.pause : T.play);
    if (spPlay) { spPlay.classList.toggle('on', on); spPlay.setAttribute('aria-label', on ? T.pause : T.listen); }
  }
  if (player) {
    au.addEventListener('error', () => missing(leadKey()));
    $('#pfile').addEventListener('change', e => {
      // files are matched to the missing tracks by name; a single file with another name stands in for the one asked for
      const files = Array.from(e.target.files || []);
      const asked = [...lost].find(inUse);
      let leadBack = false;
      for (const f of files) {
        const k = [...lost].find(x => srcs[x].name === f.name) || (files.length === 1 ? asked : null);
        if (!k) continue;
        srcs[k] = { src: URL.createObjectURL(f), name: f.name };
        lost.delete(k);
        if (k === leadKey()) leadBack = true;
        const m = mix.find(x => x.k === k);
        if (m && curKey === '*') { m.src = srcs[k].src; m.el.src = m.src; if (!au.paused) mixAlong(true, au.currentTime); }
      }
      e.target.value = '';
      showLost();
      if (leadBack) { const k = curKey; curKey = null; play(want ? want.t : 0, want ? want.end : null, k, follow); }
    });
    au.addEventListener('play', sync);
    au.addEventListener('pause', () => { if (curKey === '*') mixAlong(false); sync(); });
    au.addEventListener('timeupdate', () => {
      const t = au.currentTime;
      if (stopAt !== null && t >= stopAt) { au.pause(); stopAt = null; }
      if (curKey === '*' && !au.paused) for (const m of mix) if (!m.el.paused && Math.abs(m.el.currentTime - t) > 0.15) m.el.currentTime = t;
      $('#pcur').textContent = fmt(t);
      if (ph && D.timed) {
        const dur = isFinite(au.duration) && au.duration > 0 ? au.duration : null;
        const x = (100 * Math.min(1, t / (dur || D.duration || 1))).toFixed(3) + '%';
        ph.setAttribute('x1', x); ph.setAttribute('x2', x);
      }
      const trackSp = curKey === 'g' || curKey === '*' ? null : curKey;
      const el = segAt(t, trackSp);
      if (el === nowEl) return;
      if (nowEl) nowEl.classList.remove('now');
      nowEl = el;
      const sp = el ? D.speakers[speakerOf(el)] : null;
      $('#pwho').textContent = trackSp ? T.track.replace('{n}', D.speakers[trackSp].name) + (el ? ' ·' : '') : (sp ? sp.name : '');
      $('#ptext').textContent = el ? el.textContent : '';
      if (!el) return;
      el.classList.add('now');
      if (follow && Date.now() - lastInput > 4000) el.scrollIntoView({ block: 'center' });
    });
    $('#pp').addEventListener('click', () => { playing() ? pause() : resume(); });
    $('#px').addEventListener('click', () => {
      pause(); player.hidden = true; d.body.classList.remove('has-player');
      if (ph) ph.setAttribute('visibility', 'hidden');
      if (nowEl) nowEl.classList.remove('now');
      nowEl = null;
    });
    // the strip's button plays the meeting: the mixed file, or every track at once, never one person's alone
    if (spPlay) spPlay.addEventListener('click', () => {
      const open = curKey && !player.hidden;
      if (open && playing()) { pause(); return; }
      if (open && curKey === meetingKey() && au.currentSrc) { resume(); return; }
      play(open ? au.currentTime : 0, null, meetingKey(), false);
    });
  }

  /* ---------- one click handler for the whole page ---------- */
  d.addEventListener('click', e => {
    const b = e.target.closest('button.pl');
    if (b) {
      const seg = d.getElementById(b.dataset.sid);
      if (seg) play(+seg.dataset.s, +seg.dataset.e, keyFor(speakerOf(seg)), false);
      return;
    }
    const a = e.target.closest('a');
    if (!a) return;
    const href = a.getAttribute('href') || '';
    if (href[0] !== '#' || href.length < 2) return;
    const id = decodeURIComponent(href.slice(1));
    if (a.matches('a.ts')) { e.preventDefault(); togglePanel(a); return; }
    if (a.matches('a.tt')) {
      e.preventDefault();
      const seg = d.getElementById(id);
      history.replaceState(null, '', href);
      flash(seg);
      if (seg && player) play(+seg.dataset.s, null, meetingKey(), true);  // the meeting from here, everyone
      return;
    }
    if (id === 'top') return;
    const el = d.getElementById(id);
    if (!el) return;
    e.preventDefault();
    history.replaceState(null, '', href);
    if (el.matches('details') || id === 'lead') openItem(id);
    else jump(el, el.matches('.chh') ? 'start' : 'center');
  });

  /* ---------- search: case and ё ignored, glossary spellings included ---------- */
  const q = $('#q'), hitsEl = $('#hits'), prev = $('#prev'), next = $('#next');
  const nz = s => s.toLowerCase().replace(/ё/g, 'е');
  let marked = [], marks = [], cur = -1, timer = 0;
  function terms(raw) {
    const n = nz(raw.trim());
    const out = new Set([n]);
    for (const g of D.glossary || []) {
      const all = [g.meant].concat(g.heard).map(nz);
      if (all.includes(n)) all.forEach(x => out.add(x));
    }
    return Array.from(out).filter(x => x.length >= 2);
  }
  function unmark() {
    for (const el of marked) el.textContent = el.textContent;
    marked = []; marks = []; cur = -1;
  }
  function run() {
    unmark();
    const raw = q.value.trim();
    const ts = raw.length >= 2 ? terms(raw) : [];
    if (!ts.length) { hitsEl.textContent = raw ? T.short : ''; prev.disabled = next.disabled = true; return; }
    for (const el of segEls) {
      const text = el.textContent;
      let hay = nz(text);
      if (hay.length !== text.length) hay = text;
      const ranges = [];
      for (const t of ts) {
        let i = hay.indexOf(t);
        while (i >= 0) { ranges.push([i, i + t.length]); i = hay.indexOf(t, i + t.length); }
      }
      if (!ranges.length) continue;
      ranges.sort((x, y) => x[0] - y[0]);
      const frag = d.createDocumentFragment();
      let p = 0;
      for (const [a, b] of ranges) {
        if (a < p) continue;
        frag.append(text.slice(p, a));
        const m = d.createElement('mark');
        m.textContent = text.slice(a, b);
        frag.append(m);
        marks.push(m);
        p = b;
      }
      frag.append(text.slice(p));
      el.replaceChildren(frag);
      marked.push(el);
    }
    prev.disabled = next.disabled = !marks.length;
    if (!marks.length) { hitsEl.textContent = T.noHits; return; }
    go(0);
  }
  function go(i) {
    if (!marks.length) return;
    if (cur >= 0) marks[cur].classList.remove('cur');
    cur = (i + marks.length) % marks.length;
    marks[cur].classList.add('cur');
    land(marks[cur], 'center');
    hitsEl.textContent = `${cur + 1} ${T.of} ${marks.length}`;
  }
  if (q) {
    q.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(run, 120); });
    q.addEventListener('keydown', e => {
      const fresh = () => { clearTimeout(timer); if (!marks.length) { run(); return true; } return false; };
      if (e.key === 'Enter' || e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        if (fresh()) return;
        go(cur + ((e.key === 'ArrowUp' || (e.key === 'Enter' && e.shiftKey)) ? -1 : 1));
      } else if (e.key === 'Escape') { q.value = ''; run(); }
    });
    prev.addEventListener('click', () => go(cur - 1));
    next.addEventListener('click', () => go(cur + 1));
    d.addEventListener('keydown', e => {
      if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
      const a = d.activeElement;
      if (a && (/^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) || a.isContentEditable)) return;
      e.preventDefault();
      q.focus();
      q.select();
    });
  }

  /* ---------- chapters follow the reader ---------- */
  const heads = $$('.tx-body .chh');
  const navLinks = $$('.tx-ch a[data-ch]');
  const sel = $('#chsel'), side = $('.tx-side');
  // on one column the search bar sticks over the transcript: jumps land below it (--bar in the CSS)
  const bar = $('.tx-search');
  let barPx = 0;
  function measureBar() {
    barPx = bar && getComputedStyle(bar).position === 'sticky' ? bar.offsetHeight : 0;
    d.documentElement.style.setProperty('--bar', barPx + 'px');
  }
  if (bar) {
    measureBar();
    addEventListener('resize', measureBar, { passive: true });
    if (window.ResizeObserver) new ResizeObserver(measureBar).observe(bar);
  }
  if (sel) sel.addEventListener('change', () => { const h = d.getElementById(sel.value); if (h) jump(h, 'start'); });
  let ticking = false, onId = null;
  function spy() {
    ticking = false;
    if (!heads.length) return;
    let lo = 0, hi = heads.length - 1, ans = 0;
    const line = barPx + 140;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (heads[m].getBoundingClientRect().top < line) { ans = m; lo = m + 1; } else hi = m - 1; }
    // at the very end the last headings cannot reach the line: the last one on screen is current
    if (innerHeight + scrollY >= d.documentElement.scrollHeight - 4)
      while (ans + 1 < heads.length && heads[ans + 1].getBoundingClientRect().top < innerHeight) ans++;
    const id = heads[ans].id;
    if (id === onId) return;
    onId = id;
    navLinks.forEach(a => a.classList.toggle('on', a.dataset.ch === id));
    if (sel) sel.value = id;
    // a long chapter list scrolls on its own: keep the current chapter in sight
    const on = navLinks.find(a => a.dataset.ch === id);
    if (on && on.offsetParent && side.scrollHeight > side.clientHeight) {
      const r = on.getBoundingClientRect(), s = side.getBoundingClientRect();
      if (r.top < Math.max(s.top, 0) + 8 || r.bottom > Math.min(s.bottom, innerHeight) - 8) side.scrollTop += r.top - s.top - side.clientHeight / 3;
    }
  }
  addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(spy); } }, { passive: true });
  spy();

  /* ---------- copy the tasks as a Markdown checklist ---------- */
  const copy = $('#copy');
  if (copy) copy.addEventListener('click', async () => {
    let ok = false;
    try { await navigator.clipboard.writeText(D.copy); ok = true; } catch (e) {
      const ta = d.createElement('textarea');
      ta.value = D.copy; ta.setAttribute('readonly', ''); ta.className = 'sr';
      d.body.append(ta); ta.select();
      try { ok = d.execCommand('copy'); } catch (e2) { ok = false; }
      ta.remove();
    }
    const was = copy.textContent;
    copy.textContent = ok ? T.copied : T.copyFail;
    setTimeout(() => { copy.textContent = was; }, 2000);
  });

  /* ---------- print every fold open (the print style keeps each item's main quote) ---------- */
  let closed = [];
  addEventListener('beforeprint', () => { closed = $$('details:not([open])'); closed.forEach(x => { x.open = true; }); });
  addEventListener('afterprint', () => { closed.forEach(x => { x.open = false; }); closed = []; });

  if (location.hash.length > 1) {
    const el = d.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (el && el.matches('details')) { el.open = true; land(el, 'center'); }
    if (el && el.matches('.sg')) { el.classList.add('here'); land(el, 'center'); }
  }
})();
