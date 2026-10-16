/* Explorer: topic tree · timeline · detail (payload / diff / chart), publish, search. */
(function () {
  'use strict';

  const { esc } = MS;
  const $ = (id) => document.getElementById(id);

  const RANGES = { '15m': 15 * 60e3, '1h': 3600e3, '6h': 6 * 3600e3, '24h': 24 * 3600e3, '7d': 7 * 24 * 3600e3 };
  const TICK_MS = 5000;           // tree rate/preview refresh
  const FLUSH_MS = 120;           // live timeline batching
  const TREE_RENDER_MAX = 4000;   // rows rendered before "refine the filter"
  const OPEN_STATE_MAX = 3000;    // persisted expand/collapse entries
  const PREVIEW_CHARS = 48;
  const DIFF_CACHE_MAX = 50;
  const CHART_LIVE_MAX = 5000;

  const S = {
    topics: new Map(),            // topic -> {topic, count, rate, retained, last_seen_ms, first_seen_ms, preview, hits, buckets}
    maxTopics: 20000,
    rateWindowS: 60,
    ticks: 0,
    open: MS.load('ms.tree.open', {}),
    filter: '',
    rowEls: new Map(),
    selected: null,
    messages: [],                 // newest first
    byKey: new Map(),
    pending: [],
    flushTimer: null,
    selectedMsg: null,
    hasMore: false,
    effCap: 0,
    cap: Number(MS.load('ms.timelineCap', 500)) || 500,
    range: MS.load('ms.range', '1h'),
    custom: { from: null, to: null },
    paused: false,
    missed: 0,
    dedup: true,
    publishEnabled: true,
    tab: 'payload',
    diffCache: new Map(),
    chart: null,
    chartTopic: null,
    chartPaths: [],
    chartPathByTopic: MS.load('ms.chartPath', {}),
    historyCtl: null,
    pageSize: 200,
    seq: 0
  };
  S.effCap = S.cap;

  // ─── Helpers ────────────────────────────────────────────
  function bounds() {
    if (S.range === 'custom') {
      const to = S.custom.to;
      return { from_ms: S.custom.from, to_ms: to, live: !to || to > Date.now() };
    }
    return { from_ms: Date.now() - (RANGES[S.range] || RANGES['1h']), to_ms: null, live: true };
  }

  function norm(m, live) {
    const binary = !!m.binary || ((m.payload === null || m.payload === undefined) && !!m.payload_b64);
    const id = m.id ?? null;
    return {
      key: id !== null ? `i${id}` : `l${++S.seq}`,
      id,
      topic: m.topic,
      ts_ms: m.ts_ms,
      payload: binary ? null : (m.payload ?? ''),
      binary,
      payload_b64: m.payload_b64 || null,
      size: m.size ?? (m.payload ? new TextEncoder().encode(m.payload).length : 0),
      retained: !!m.retained,
      qos: m.qos ?? 0,
      origin: m.origin || 'broker',
      dup_count: m.dup_count || 0,
      truncated: !!m.truncated,
      stored: live ? m.stored !== false && id !== null : true,
      live: !!live
    };
  }

  function shortPreview(m) {
    if (m.binary) return `binary · ${MS.fmtBytes(m.size)}`;
    if (!m.payload) return '(empty)';
    return m.payload.slice(0, 400).replace(/\s+/g, ' ');
  }

  function treePreview(payload, binary) {
    if (binary) return null;
    if (payload === null || payload === undefined) return null;
    const s = String(payload).trim();
    if (!s || s.length > PREVIEW_CHARS || s.startsWith('{') || s.startsWith('[')) return null;
    return s;
  }

  // Glob when the filter contains MQTT/glob wildcards, case-insensitive substring otherwise.
  function makeMatcher(filter) {
    const f = filter.trim();
    if (!f) return null;
    if (/[*?+#]/.test(f)) {
      const re = f.split('').map((c) => {
        if (c === '*' || c === '#') return '.*';
        if (c === '?') return '.';
        if (c === '+') return '[^/]*';
        return c.replace(/[.^$|()[\]{}\\]/g, '\\$&');
      }).join('');
      let rx;
      try { rx = new RegExp(`^${re}$`, 'i'); } catch { return () => false; }
      return { test: (t) => rx.test(t), substring: null };
    }
    const needle = f.toLowerCase();
    return { test: (t) => t.toLowerCase().includes(needle), substring: needle };
  }

  function highlightName(name, needle) {
    if (!needle) return esc(name);
    const lower = name.toLowerCase();
    let out = '';
    let i = 0;
    for (;;) {
      const j = lower.indexOf(needle, i);
      if (j < 0) break;
      out += `${esc(name.slice(i, j))}<mark>${esc(name.slice(j, j + needle.length))}</mark>`;
      i = j + needle.length;
    }
    return out + esc(name.slice(i));
  }

  // ─── Topic registry (client side) ───────────────────────
  function bucketsLen() { return Math.max(1, Math.ceil((S.rateWindowS * 1000) / TICK_MS)); }

  function upsertTopic(raw) {
    let e = S.topics.get(raw.topic);
    if (!e) {
      if (S.topics.size >= S.maxTopics) return null;
      e = { topic: raw.topic, count: 0, rate: 0, seedRate: 0, retained: false, last_seen_ms: null, first_seen_ms: null, preview: null, hits: 0, buckets: null, stored: null };
      S.topics.set(raw.topic, e);
    }
    return e;
  }

  function loadTopicList(list) {
    S.topics.clear();
    S.ticks = 0;
    (list || []).forEach((t) => {
      const e = upsertTopic(t);
      if (!e) return;
      e.count = t.count ?? 0;
      e.rate = e.seedRate = Number(t.rate) || 0;
      e.retained = !!t.retained;
      e.last_seen_ms = t.last_seen_ms ?? null;
      e.first_seen_ms = t.first_seen_ms ?? null;
      e.last_size = t.last_size ?? null;
      e.stored = t.stored_count ?? t.stored ?? t.messages ?? null;
      e.preview = treePreview(t.last_payload, t.binary);
    });
  }

  // Rate = messages seen in the last rate_window_s, seeded with the server's figure until a full window was observed.
  function tickRates() {
    const n = bucketsLen();
    S.ticks++;
    const filled = Math.min(S.ticks, n);
    S.topics.forEach((e) => {
      if (!e.hits && !e.buckets && !e.seedRate) { e.rate = 0; return; }
      if (!e.buckets) e.buckets = [];
      e.buckets.push(e.hits);
      e.hits = 0;
      while (e.buckets.length > n) e.buckets.shift();
      const sum = e.buckets.reduce((a, b) => a + b, 0);
      const seeded = e.seedRate * (TICK_MS / 1000) * (n - filled);
      e.rate = (sum + seeded) / (n * (TICK_MS / 1000));
      if (!sum && filled >= n) { e.buckets = null; e.seedRate = 0; }
    });
  }

  // ─── Tree ───────────────────────────────────────────────
  function buildTree(entries) {
    const root = { children: new Map() };
    entries.forEach((e) => {
      const parts = e.topic.split('/');
      let node = root;
      let path = '';
      parts.forEach((seg, i) => {
        path = i === 0 ? seg : `${path}/${seg}`;
        let child = node.children.get(seg);
        if (!child) { child = { name: seg, path, children: new Map(), entry: null, count: 0, depth: i }; node.children.set(seg, child); }
        child.count++;
        node = child;
      });
      node.entry = e;
    });
    return root;
  }

  function isOpen(node) {
    const v = S.open[node.path];
    if (v !== undefined) return v;
    return node.depth === 0 && node.path !== '$SYS';
  }

  function setOpen(path, value) {
    delete S.open[path];
    S.open[path] = value;
    const keys = Object.keys(S.open);
    if (keys.length > OPEN_STATE_MAX) keys.slice(0, keys.length - OPEN_STATE_MAX).forEach((k) => delete S.open[k]);
    MS.save('ms.tree.open', S.open);
  }

  function leafBadges(e) {
    let html = '';
    if (e.retained) html += '<span class="t-badge" data-size="xs" data-tone="purple" title="Last message was retained">retained</span>';
    if (e.rate > 0.0005) html += `<span class="t-badge" data-size="xs" data-tone="cyan" title="Messages per second over the rate window">${esc(MS.fmtRate(e.rate))}</span>`;
    return html;
  }

  function badgesHTML(node) {
    let html = '';
    if (node.children.size && !(S.filter || isOpen(node))) html += `<span class="tree-count" title="Topics below">${MS.fmtNum(node.count)}</span>`;
    if (node.entry) html += leafBadges(node.entry);
    return html;
  }

  function renderTree() {
    const box = $('tree');
    const matcher = makeMatcher(S.filter);
    const all = [...S.topics.values()];
    const entries = matcher ? all.filter((e) => matcher.test(e.topic)) : all;
    $('topic-count').textContent = matcher
      ? `${MS.fmtNum(entries.length)} of ${MS.fmtNum(all.length)} topics match`
      : `${MS.fmtNum(all.length)} topics`;

    if (!all.length) { box.innerHTML = MS.empty('hourglass-split', 'No topics yet.', 'They appear here as soon as the broker delivers messages.'); S.rowEls.clear(); return; }
    if (!entries.length) { box.innerHTML = MS.empty('funnel', 'No topics match the filter.', 'Plain text matches anywhere; + * # and ? make it a glob.'); S.rowEls.clear(); return; }

    const root = buildTree(entries);
    const needle = matcher?.substring;
    const force = !!matcher;
    let rendered = 0;
    let skipped = 0;

    const sortNodes = (nodes, depth) => [...nodes].sort((a, b) => {
      if (depth === 0 && (a.name === '$SYS') !== (b.name === '$SYS')) return a.name === '$SYS' ? 1 : -1;
      return a.name.localeCompare(b.name, undefined, { numeric: true });
    });

    const renderNode = (node) => {
      if (rendered >= TREE_RENDER_MAX) { skipped += node.count; return ''; }
      rendered++;
      const kids = node.children.size > 0;
      const open = kids && (force || isOpen(node));
      const e = node.entry;
      const cls = ['tree-row'];
      if (kids) cls.push('is-folder');
      if (node.path === '$SYS' || node.path.startsWith('$SYS/')) cls.push('is-sys');
      if (e && S.selected === node.path) cls.push('selected');
      const name = node.name === '' ? '(empty)' : node.name;
      let html = `<div class="${cls.join(' ')}" data-path="${esc(node.path)}"${e ? ` data-topic="${esc(node.path)}"` : ''} title="${esc(node.path)}">`
        + `${MS.icon('chevron-right', `tree-toggle${kids ? (open ? ' open' : '') : ' leaf'}`)}`
        + `<span class="tree-name">${highlightName(name, needle)}</span>`
        + `${e && e.preview !== null ? `<span class="tree-value">= ${esc(e.preview)}</span>` : ''}`
        + `<span class="tree-badges">${badgesHTML(node)}</span></div>`;
      if (open) html += `<ul>${sortNodes(node.children.values(), node.depth + 1).map((c) => `<li>${renderNode(c)}</li>`).join('')}</ul>`;
      return html;
    };

    const scroll = box.scrollTop;
    let html = `<ul class="tree">${sortNodes(root.children.values(), 0).map((c) => `<li>${renderNode(c)}</li>`).join('')}</ul>`;
    if (skipped) html += `<div class="t-empty" data-size="sm">${MS.fmtNum(skipped)} more topics not shown — refine the filter.</div>`;
    box.innerHTML = html;
    box.scrollTop = scroll;

    S.rowEls.clear();
    box.querySelectorAll('.tree-row[data-topic]').forEach((el) => S.rowEls.set(el.dataset.topic, el));
  }

  let treeTimer = null;
  function scheduleTree(delay = 400) {
    if (treeTimer) return;
    treeTimer = setTimeout(() => { treeTimer = null; renderTree(); }, delay);
  }

  // Cheap in-place refresh of the visible leaf rows (rates, retained, value preview).
  function refreshVisibleRows() {
    S.rowEls.forEach((el, topic) => {
      const e = S.topics.get(topic);
      if (!e) return;
      const badges = el.querySelector('.tree-badges');
      const keepCount = badges.querySelector('.tree-count')?.outerHTML || '';
      badges.innerHTML = keepCount + leafBadges(e);
      const val = el.querySelector('.tree-value');
      if (e.preview !== null) {
        if (val) val.textContent = `= ${e.preview}`;
        else el.querySelector('.tree-name').insertAdjacentHTML('afterend', `<span class="tree-value">= ${esc(e.preview)}</span>`);
      } else if (val) val.remove();
    });
  }

  function pulse(topic) {
    let path = topic;
    for (;;) {
      const el = S.rowEls.get(path) || (path !== topic ? $('tree').querySelector(`.tree-row[data-path="${CSS.escape(path)}"]`) : null);
      if (el) {
        if (!el.classList.contains('pulse')) {
          el.classList.add('pulse');
          setTimeout(() => el.classList.remove('pulse'), 800);
        }
        return;
      }
      const i = path.lastIndexOf('/');
      if (i < 0) return;
      path = path.slice(0, i);
    }
  }

  function expandTo(topic) {
    const parts = topic.split('/');
    let path = '';
    parts.slice(0, -1).forEach((seg, i) => {
      path = i === 0 ? seg : `${path}/${seg}`;
      if (S.open[path] !== true) setOpen(path, true);
    });
  }

  // ─── Timeline ───────────────────────────────────────────
  function rowBadges(m) {
    let b = '';
    if (m.retained) b += '<span class="t-badge" data-size="xs" data-tone="purple">retained</span>';
    if (m.origin === 'ui') b += '<span class="t-badge" data-size="xs" data-tone="pink" title="Published from mqttscope">ui</span>';
    if (m.dup_count > 0) b += `<span class="t-badge" data-size="xs" data-tone="orange" title="Received> ${m.dup_count + 1} times; ${m.dup_count} identical repeats folded into this row">×${m.dup_count + 1}</span>`;
    if (!m.stored) b += '<span class="t-badge" data-size="xs" data-tone="neutral" title="Seen live but not stored (sampling or dedup)">not stored</span>';
    if (m.truncated) b += '<span class="t-badge" data-size="xs" data-tone="yellow" title="Stored truncated to max_payload_bytes">truncated</span>';
    return b;
  }

  function rowHTML(m, fresh) {
    const day = MS.isToday(m.ts_ms) ? '' : `<span class="tl-date">${MS.fmtDay(m.ts_ms)} </span>`;
    const sel = S.selectedMsg && S.selectedMsg.key === m.key ? ' selected' : '';
    return `<div class="tl-row${sel}${fresh ? ' fresh' : ''}" data-key="${m.key}" title="${esc(MS.fmtISO(m.ts_ms))}">`
      + `<span class="tl-time">${day}${MS.fmtClock(m.ts_ms)}</span>`
      + `<span class="tl-size">${MS.fmtBytes(m.size)}</span>`
      + `<span class="tl-preview">${esc(shortPreview(m))}</span>`
      + `<span class="tl-badges">${rowBadges(m)}</span></div>`;
  }

  function rowEl(key) { return $('timeline').querySelector(`.tl-row[data-key="${key}"]`); }

  function timelineEmpty() {
    const box = $('timeline');
    if (!S.selected) { box.innerHTML = MS.empty('diagram-3', 'Pick a topic on the left to see its messages.', null, false); return; }
    const b = bounds();
    box.innerHTML = MS.empty('inbox', 'No stored messages in this range.',
      b.live ? 'New messages show up here live. Sampling rules may keep busy topics sparse.' : 'Try a wider range.', false);
  }

  function renderTimeline() {
    const box = $('timeline');
    if (!S.messages.length) { timelineEmpty(); return; }
    box.innerHTML = S.messages.map((m) => rowHTML(m, false)).join('');
  }

  function renderTimelineHead() {
    const title = $('tl-title');
    const meta = $('tl-meta');
    if (!S.selected) {
      title.textContent = 'No topic selected';
      title.classList.add('t-muted');
      meta.innerHTML = '';
      return;
    }
    title.textContent = S.selected;
    title.classList.remove('t-muted');
    const e = S.topics.get(S.selected);
    const bits = [];
    if (e) {
      bits.push(`<span title="Messages received since mqttscope started tracking it">${MS.fmtNum(e.count)} received</span>`);
      if (e.stored !== null && e.stored !== undefined) bits.push(`<span>${MS.fmtNum(e.stored)} stored</span>`);
      bits.push(`<span>${esc(MS.fmtRate(e.rate))}</span>`);
      if (e.last_seen_ms) bits.push(`<span title="${esc(MS.fmtISO(e.last_seen_ms))}">last ${esc(MS.fmtRel(e.last_seen_ms))}</span>`);
      if (e.retained) bits.push('<span class="t-badge" data-size="xs" data-tone="purple">retained</span>');
    }
    meta.innerHTML = bits.join('');
  }

  function renderTimelineStatus() {
    const st = $('tl-status');
    if (!S.selected) { st.textContent = ''; return; }
    const parts = [`${MS.fmtNum(S.messages.length)} rows`];
    if (S.paused) parts.push(`paused${S.missed ? ` · ${MS.fmtNum(S.missed)} new` : ''}`);
    else if (!bounds().live) parts.push('history only');
    else parts.push('live');
    st.textContent = parts.join(' · ');
    $('load-more').hidden = !S.hasMore;
  }

  async function loadHistory({ keepSelection } = {}) {
    if (!S.selected) return;
    S.historyCtl?.abort();
    const ctl = (S.historyCtl = new AbortController());
    const topic = S.selected;
    const b = bounds();
    S.pending = [];
    S.missed = 0;
    $('timeline').innerHTML = MS.loading();
    try {
      const res = await MS.getJSON(`/api/messages${MS.qs({ topic, from_ms: b.from_ms, to_ms: b.to_ms, limit: S.pageSize })}`, { signal: ctl.signal });
      if (topic !== S.selected) return;
      const list = (res.messages || []).map((m) => norm(m, false));
      S.messages = list;
      S.byKey = new Map(list.map((m) => [m.key, m]));
      S.effCap = Math.max(S.cap, list.length);
      S.hasMore = list.length >= S.pageSize;
      $('timeline').classList.toggle('wide-time', list.some((m) => !MS.isToday(m.ts_ms)));
      renderTimeline();
      if (!keepSelection || !S.selectedMsg || S.selectedMsg.topic !== topic) selectMessage(list[0] || null);
    } catch (e) {
      if (e.name === 'AbortError') return;
      S.messages = [];
      S.byKey = new Map();
      S.hasMore = false;
      $('timeline').innerHTML = MS.empty('exclamation-triangle', `Could not load history: ${e.message}`, null, false);
    } finally {
      renderTimelineStatus();
    }
  }

  async function loadMore(btn) {
    const ids = S.messages.map((m) => m.id).filter((id) => id !== null);
    if (!ids.length) { S.hasMore = false; renderTimelineStatus(); return; }
    const b = bounds();
    const topic = S.selected;
    await MS.busy(btn, async () => {
      try {
        const res = await MS.getJSON(`/api/messages${MS.qs({ topic, from_ms: b.from_ms, to_ms: b.to_ms, before_id: Math.min(...ids), limit: S.pageSize })}`);
        if (topic !== S.selected) return;
        const list = (res.messages || []).map((m) => norm(m, false)).filter((m) => !S.byKey.has(m.key));
        list.forEach((m) => { S.messages.push(m); S.byKey.set(m.key, m); });
        S.effCap = Math.max(S.cap, S.messages.length);
        S.hasMore = list.length >= S.pageSize;
        if (list.some((m) => !MS.isToday(m.ts_ms))) $('timeline').classList.add('wide-time');
        if (list.length) $('timeline').insertAdjacentHTML('beforeend', list.map((m) => rowHTML(m, false)).join(''));
        else MS.toast('warning', 'No older messages in this range');
      } catch (e) {
        MS.toast('error', `Could not load more: ${e.message}`);
      }
    });
    renderTimelineStatus();
  }

  function samePayload(a, b) {
    return a.binary === b.binary && (a.binary ? a.payload_b64 === b.payload_b64 && a.size === b.size : a.payload === b.payload);
  }

  function queueLive(m) {
    S.pending.push(m);
    if (S.pending.length > S.cap) S.pending.splice(0, S.pending.length - S.cap);
    if (!S.flushTimer) S.flushTimer = setTimeout(flushLive, FLUSH_MS);
  }

  function flushLive() {
    S.flushTimer = null;
    const batch = S.pending.splice(0);
    if (!batch.length) return;
    const box = $('timeline');
    const wasEmpty = !S.messages.length;
    const inserted = [];
    const folded = new Set();

    batch.forEach((m) => {
      if (m.topic !== S.selected || S.byKey.has(m.key)) return;
      const top = S.messages[0];
      if (!m.stored && S.dedup && top && samePayload(top, m)) {
        top.dup_count++;
        if (!inserted.includes(top)) folded.add(top.key);
        return;
      }
      S.messages.unshift(m);
      S.byKey.set(m.key, m);
      inserted.push(m);
    });

    if (inserted.length) {
      if (wasEmpty) box.innerHTML = '';
      const prevH = box.scrollHeight;
      const prevTop = box.scrollTop;
      box.insertAdjacentHTML('afterbegin', inserted.slice().reverse().map((m) => rowHTML(m, true)).join(''));
      if (prevTop > 0) box.scrollTop = prevTop + (box.scrollHeight - prevH);
    }
    folded.forEach((key) => {
      const m = S.byKey.get(key);
      const el = rowEl(key);
      if (m && el) el.querySelector('.tl-badges').innerHTML = rowBadges(m);
    });

    while (S.messages.length > S.effCap) {
      const old = S.messages.pop();
      S.byKey.delete(old.key);
      rowEl(old.key)?.remove();
      S.hasMore = true;
    }
    if (!S.selectedMsg && S.messages.length) selectMessage(S.messages[0]);
    renderTimelineStatus();
  }

  // ─── Detail ─────────────────────────────────────────────
  function highlightJSON(str) {
    const re = /("(?:\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*")(\s*:)?|\b(true|false)\b|\bnull\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g;
    let out = '';
    let last = 0;
    str.replace(re, (match, s, colon, bool, offset) => {
      out += esc(str.slice(last, offset));
      let cls = 'j-num';
      if (s !== undefined) cls = colon ? 'j-key' : 'j-str';
      else if (bool !== undefined) cls = 'j-bool';
      else if (match === 'null') cls = 'j-null';
      out += colon ? `<span class="${cls}">${esc(s)}</span>${esc(colon)}` : `<span class="${cls}">${esc(match)}</span>`;
      last = offset + match.length;
      return match;
    });
    return out + esc(str.slice(last));
  }

  function parseJSONObject(payload) {
    if (!payload) return undefined;
    const c = payload.trimStart()[0];
    if (c !== '{' && c !== '[') return undefined;
    try { return JSON.parse(payload); } catch { return undefined; }
  }

  function hexdump(b64, max = 512) {
    let bin;
    try { bin = atob(b64); } catch { return null; }
    const n = Math.min(bin.length, max);
    const lines = [];
    for (let off = 0; off < n; off += 16) {
      const bytes = [];
      let ascii = '';
      for (let i = off; i < Math.min(off + 16, n); i++) {
        const c = bin.charCodeAt(i);
        bytes.push(c.toString(16).padStart(2, '0'));
        ascii += c >= 32 && c < 127 ? String.fromCharCode(c) : '.';
      }
      lines.push(`${off.toString(16).padStart(6, '0')}  ${bytes.join(' ').padEnd(47)}  ${ascii}`);
    }
    if (bin.length > max) lines.push(`… ${bin.length - max} more bytes`);
    return lines.join('\n');
  }

  function renderMeta() {
    const box = $('detail-meta');
    const m = S.selectedMsg;
    $('copy-btn').hidden = !m || m.binary;
    if (!m) { box.hidden = true; box.innerHTML = ''; return; }
    box.hidden = false;
    const bits = [
      `<span class="meta-time" title="${esc(MS.fmtISO(m.ts_ms))}">${MS.isToday(m.ts_ms) ? '' : `${MS.fmtDay(m.ts_ms)} `}${MS.fmtClock(m.ts_ms)}</span>`,
      `<span>${MS.fmtBytes(m.size)}</span>`,
      `<span>QoS ${esc(m.qos)}</span>`,
      m.id !== null ? `<span class="t-mono">#${esc(m.id)}</span>` : '',
      rowBadges(m)
    ];
    box.innerHTML = bits.join('');
  }

  function renderPayload() {
    const box = $('tab-payload');
    const m = S.selectedMsg;
    if (!m) { box.innerHTML = MS.empty('cursor', S.selected ? 'Select a message in the timeline.' : 'Nothing selected.', null, false); return; }
    let kind;
    let body;
    if (m.binary) {
      const dump = m.payload_b64 ? hexdump(m.payload_b64) : null;
      kind = `binary, ${MS.fmtNum(m.size)} bytes`;
      body = dump ? `<pre class="payload hexdump">${esc(dump)}</pre>` : '';
    } else if (!m.payload) {
      kind = 'empty payload';
      body = MS.empty('dash-circle', 'Empty payload (0 bytes).');
    } else {
      const obj = parseJSONObject(m.payload);
      if (obj !== undefined) {
        kind = `JSON · ${MS.fmtBytes(m.size)}`;
        body = `<pre class="payload">${highlightJSON(JSON.stringify(obj, null, 2))}</pre>`;
      } else {
        kind = `text · ${MS.fmtBytes(m.size)}`;
        body = `<pre class="payload">${esc(m.payload)}</pre>`;
      }
    }
    const trunc = m.truncated ? ' · <span class="t-tone-text" data-tone="orange">stored truncated</span>' : '';
    box.innerHTML = `<div class="payload-kind">${esc(kind)}${trunc}</div>${body}`;
  }

  const fmtVal = (v) => {
    const s = v === undefined ? 'undefined' : JSON.stringify(v);
    return s.length > 300 ? `${s.slice(0, 300)}…` : s;
  };

  function diffRowsHTML(d) {
    if (d.kind === 'text') {
      return d.changes.map((c) => {
        const lines = [];
        if (c.op !== 'added') lines.push(`<span class="diff-line minus">- ${esc(c.from ?? '')}</span>`);
        if (c.op !== 'removed') lines.push(`<span class="diff-line plus">+ ${esc(c.to ?? '')}</span>`);
        return `<div class="diff-row op-${esc(c.op)}"><span class="diff-op">line ${esc(c.line)}</span>${lines.join('')}</div>`;
      }).join('');
    }
    return d.changes.map((c) => {
      const path = `<span class="diff-path">${esc(c.path === '' || c.path === undefined ? '(root)' : c.path)}</span>`;
      let vals;
      if (c.op === 'added') vals = `<span class="diff-op">added</span><span class="diff-new">${esc(fmtVal(c.to))}</span>`;
      else if (c.op === 'removed') vals = `<span class="diff-op">removed</span><span class="diff-old">${esc(fmtVal(c.from))}</span>`;
      else vals = `<span class="diff-old">${esc(fmtVal(c.from))}</span><span class="diff-arrow">→</span><span class="diff-new">${esc(fmtVal(c.to))}</span>`;
      return `<div class="diff-row op-${esc(c.op)}">${path}${vals}</div>`;
    }).join('');
  }

  function renderDiffResult(res) {
    const box = $('tab-diff');
    const d = res.diff;
    if (!res.from) { box.innerHTML = MS.empty('1-circle', 'First stored message on this topic — nothing to compare.', null, false); return; }
    const vs = `<span class="t-muted">vs ${esc(MS.fmtDateTime(res.from.ts_ms))}.${String(new Date(res.from.ts_ms).getMilliseconds()).padStart(3, '0')}${res.from.id !== undefined ? ` · #${esc(res.from.id)}` : ''}</span>`;
    if (!d || d.kind === 'same') { box.innerHTML = `<div class="diff-summary">${vs}</div>${MS.empty('check2-all', 'Identical to the previous stored message.')}`; return; }
    if (d.kind === 'binary') {
      box.innerHTML = `<div class="diff-summary">${esc(d.summary || 'Binary payloads differ')} ${vs}</div>`
        + MS.empty('file-binary', `Binary payloads differ (${MS.fmtBytes(res.from.size)} → ${MS.fmtBytes(res.to?.size ?? S.selectedMsg?.size)}).`);
      return;
    }
    const changes = d.changes || [];
    box.innerHTML = `<div class="diff-summary">${esc(d.summary || `${changes.length} changes`)} ${vs}</div>`
      + (changes.length ? `<div class="diff-list">${diffRowsHTML(d)}</div>` : MS.empty('check2-all', 'No differences.'));
  }

  async function renderDiff() {
    const box = $('tab-diff');
    const m = S.selectedMsg;
    if (!m) { box.innerHTML = MS.empty('file-diff', 'Select a message to compare it with the previous one.', null, false); return; }
    if (m.id === null) { box.innerHTML = MS.empty('file-diff', 'This message was not stored, so it has no diff.', 'Diffs compare stored messages; sampling or dedup skipped this one.', false); return; }
    const cached = S.diffCache.get(m.id);
    if (cached) { renderDiffResult(cached); return; }
    box.innerHTML = MS.loading();
    try {
      const res = await MS.getJSON(`/api/diff${MS.qs({ id: m.id })}`);
      S.diffCache.set(m.id, res);
      if (S.diffCache.size > DIFF_CACHE_MAX) S.diffCache.delete(S.diffCache.keys().next().value);
      if (S.selectedMsg === m && S.tab === 'diff') renderDiffResult(res);
    } catch (e) {
      if (S.selectedMsg === m) box.innerHTML = MS.empty('exclamation-triangle', `Could not load the diff: ${e.message}`, null, false);
    }
  }

  // ─── Chart ──────────────────────────────────────────────
  function valueAt(obj, path) {
    if (!path) return obj;
    const re = /[^.[\]]+|\[(\d+)\]/g;
    let cur = obj;
    let mt;
    while ((mt = re.exec(path)) !== null) {
      if (cur === null || typeof cur !== 'object') return undefined;
      cur = cur[mt[1] !== undefined ? Number(mt[1]) : mt[0]];
    }
    return cur;
  }

  function chartEmpty(icon, text, hint) {
    S.chart?.destroy();
    S.chart = null;
    $('chart-box').innerHTML = '';
    const el = $('chart-empty');
    el.innerHTML = MS.empty(icon, text, hint, false);
    el.hidden = false;
  }

  async function loadPaths() {
    const sel = $('chart-path');
    const topic = S.selected;
    S.chartTopic = topic;
    S.chartPaths = [];
    sel.innerHTML = '';
    try {
      const res = await MS.getJSON(`/api/paths${MS.qs({ topic })}`);
      if (topic !== S.selected) return;
      S.chartPaths = res.paths || [];
    } catch (e) {
      S.chartPaths = [];
      MS.toast('error', `Could not load numeric paths: ${e.message}`);
    }
    sel.innerHTML = S.chartPaths.map((p) => `<option value="${esc(p)}">${esc(p === '' ? '(value)' : p)}</option>`).join('');
    const remembered = S.chartPathByTopic[topic];
    if (remembered !== undefined && S.chartPaths.includes(remembered)) sel.value = remembered;
    sel.disabled = !S.chartPaths.length;
  }

  async function renderChart(force = false) {
    const topic = S.selected;
    if (!topic) { chartEmpty('graph-up', 'Pick a topic to chart its numeric fields.'); return; }
    if (force || S.chartTopic !== topic) await loadPaths();
    if (topic !== S.selected || S.tab !== 'chart') return;
    if (!S.chartPaths.length) { chartEmpty('graph-up', 'No numeric fields in the latest payload.', 'Charts need a number, or JSON with numeric values.'); return; }
    const path = $('chart-path').value;
    const b = bounds();
    const box = $('chart-box');
    const maxPoints = Math.max(100, Math.min(2000, box.clientWidth || 600));
    $('chart-empty').hidden = true;
    try {
      const res = await MS.getJSON(`/api/series${MS.qs({ topic, path: path === '' ? '.' : path, from_ms: b.from_ms, to_ms: b.to_ms ?? Date.now(), max_points: maxPoints })}`);
      if (topic !== S.selected || S.tab !== 'chart' || $('chart-path').value !== path) return;
      const data = MS.toColumns(res.points);
      if (!data[0].length) { chartEmpty('graph-down', 'No stored values for this path in the range.', 'Try a wider range.'); return; }
      $('chart-empty').hidden = true;
      S.chart?.destroy();
      const pane = $('tab-chart');
      const height = Math.max(160, pane.clientHeight - $('chart-path').offsetHeight - 80);
      S.chart = MS.chart(box, { data, label: path === '' ? topic : path, color: 'purple', height });
      S.chart.path = path;
      S.chart.live = b.live;
    } catch (e) {
      chartEmpty('exclamation-triangle', `Could not load the series: ${e.message}`);
    }
  }

  function chartLive(m) {
    if (!S.chart || !S.chart.live || S.tab !== 'chart' || m.binary || !m.payload) return;
    let v;
    if (S.chart.path === '') v = Number(m.payload);
    else {
      const obj = parseJSONObject(m.payload);
      if (obj === undefined) return;
      v = Number(valueAt(obj, S.chart.path));
    }
    if (!Number.isFinite(v)) return;
    const xs = S.chart.data[0];
    const x = m.ts_ms / 1000;
    if (xs.length && x <= xs[xs.length - 1]) return;
    S.chart.push(x, v, CHART_LIVE_MAX);
  }

  // ─── Selection ──────────────────────────────────────────
  function showTab(tab) {
    S.tab = tab;
    document.querySelectorAll('.pane-tabs [role="tab"]').forEach((b) => {
      const on = b.dataset.tab === tab;
      b.setAttribute('aria-selected', on);
      b.tabIndex = on ? 0 : -1;
    });
    ['payload', 'diff', 'chart'].forEach((t) => { $(`tab-${t}`).hidden = t !== tab; });
    if (tab === 'payload') renderPayload();
    else if (tab === 'diff') renderDiff();
    else renderChart();
  }

  function selectMessage(m) {
    S.selectedMsg = m;
    $('timeline').querySelectorAll('.tl-row.selected').forEach((el) => el.classList.remove('selected'));
    if (m) rowEl(m.key)?.classList.add('selected');
    renderMeta();
    if (S.tab === 'payload') renderPayload();
    else if (S.tab === 'diff') renderDiff();
  }

  async function selectTopic(topic, { messageId } = {}) {
    const changed = S.selected !== topic;
    S.selected = topic;
    MS.save('ms.selected', topic);
    history.replaceState(null, '', `#topic=${encodeURIComponent(topic)}`);
    if (changed) {
      S.selectedMsg = null;
      expandTo(topic);
      renderTree();
      S.rowEls.get(topic)?.scrollIntoView({ block: 'nearest' });
    } else {
      $('tree').querySelectorAll('.tree-row.selected').forEach((el) => el.classList.remove('selected'));
      S.rowEls.get(topic)?.classList.add('selected');
    }
    renderTimelineHead();
    await loadHistory();
    if (messageId !== undefined && messageId !== null) {
      const hit = S.byKey.get(`i${messageId}`);
      if (hit) { selectMessage(hit); rowEl(hit.key)?.scrollIntoView({ block: 'nearest' }); }
      else {
        try {
          const res = await MS.getJSON(`/api/messages/${encodeURIComponent(messageId)}`);
          if (res.message) selectMessage(norm(res.message, false));
        } catch (e) {
          MS.toast('error', `Could not load message #${messageId}: ${e.message}`);
        }
      }
    }
    if (S.tab === 'chart') renderChart();
  }

  // ─── Publish ────────────────────────────────────────────
  let pubConfirm = false;
  function resetPublishConfirm() {
    pubConfirm = false;
    const btn = $('pub-submit');
    btn.dataset.variant = 'primary';
    delete btn.dataset.tone;
    btn.innerHTML = MS.icon('send') + 'Publish';
    $('pub-confirm-text').hidden = true;
  }

  function payloadHint() {
    const p = $('pub-payload').value;
    const hint = $('pub-hint');
    const bytes = new TextEncoder().encode(p).length;
    const c = p.trimStart()[0];
    let note = '';
    if (c === '{' || c === '[') {
      try { JSON.parse(p); note = ' · valid JSON'; } catch { note = ' · not valid JSON, will be sent as text'; }
    }
    hint.textContent = `${MS.fmtBytes(bytes)}${note}`;
  }

  function openPublish() {
    $('pub-topic').value = S.selected || '';
    const m = S.selectedMsg;
    $('pub-payload').value = m && !m.binary && m.topic === S.selected ? (m.payload || '') : '';
    $('pub-retain').checked = false;
    $('pub-qos').value = '0';
    resetPublishConfirm();
    payloadHint();
    const dlg = $('publish-modal');
    if (!dlg.open) dlg.showModal();
    $('pub-topic').focus();
  }

  async function submitPublish(ev) {
    ev.preventDefault();
    const topic = $('pub-topic').value.trim();
    const payload = $('pub-payload').value;
    const retain = $('pub-retain').checked;
    const qos = Number($('pub-qos').value);
    if (!topic) { MS.toast('warning', 'Topic is required'); return; }
    if (/[+#]/.test(topic)) { MS.toast('warning', 'Topics to publish cannot contain + or #'); return; }
    if (!pubConfirm) {
      pubConfirm = true;
      const btn = $('pub-submit');
      btn.dataset.variant = 'solid';
      btn.dataset.tone = 'warning';
      btn.innerHTML = MS.icon('exclamation-triangle') + 'Confirm publish';
      const t = $('pub-confirm-text');
      t.textContent = `Send ${MS.fmtBytes(new TextEncoder().encode(payload).length)} to ${topic} (QoS ${qos}${retain ? ', retained' : ''})?`;
      t.hidden = false;
      return;
    }
    const btn = $('pub-submit');
    await MS.busy(btn, async () => {
      const res = await MS.postAction('/api/publish', { topic, payload, retain, qos });
      MS.toastResult(res);
      if (res.ok) $('publish-modal').close();
    });
    resetPublishConfirm();
  }

  // ─── Search ─────────────────────────────────────────────
  // The API marks hits as «term»; fall back to highlighting the query terms ourselves.
  function markTerms(text, q) {
    if (/«[^»]*»/.test(text)) return esc(text).replace(/«([^»]*)»/g, '<mark>$1</mark>');
    const terms = q.split(/\s+/).map((t) => t.replace(/["*()]/g, '')).filter((t) => t.length > 1);
    let html = esc(text);
    if (!terms.length) return html;
    const rx = new RegExp(`(${terms.map((t) => esc(t).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
    return html.replace(rx, '<mark>$1</mark>');
  }

  async function runSearch(ev) {
    ev.preventDefault();
    const q = $('search-q').value.trim();
    if (!q) { MS.toast('warning', 'Type something to search for'); return; }
    const scoped = $('search-scope').checked && S.selected;
    const b = bounds();
    const summary = $('search-summary');
    const results = $('search-results');
    summary.textContent = `Searching “${q}”${scoped ? ` in ${S.selected}` : ''}…`;
    results.innerHTML = MS.loading();
    const dlg = $('search-modal');
    if (!dlg.open) dlg.showModal();
    try {
      const res = await MS.getJSON(`/api/search${MS.qs({ q, topic: scoped ? S.selected : null, from_ms: b.from_ms, to_ms: b.to_ms })}`);
      const list = res.results || [];
      summary.textContent = `${MS.fmtNum(list.length)} result${list.length === 1 ? '' : 's'} for “${q}”${scoped ? ` in ${S.selected}` : ''} · ${$('range').selectedOptions[0].textContent.toLowerCase()}`;
      if (!list.length) { results.innerHTML = MS.empty('search', 'Nothing matched.', 'Search covers stored payloads only; try a wider time range.', false); return; }
      results.innerHTML = list.map((r, i) => `<button type="button" class="search-result" data-i="${i}">`
        + `<div class="search-result-head"><span class="search-result-topic">${esc(r.topic)}</span>`
        + `<span class="tl-size">${MS.fmtBytes(r.size)}</span>`
        + `<span class="search-result-time" title="${esc(MS.fmtISO(r.ts_ms))}">${esc(MS.fmtDateTime(r.ts_ms))}</span></div>`
        + `<div class="search-snippet">${markTerms(r.snippet ?? '', q)}</div></button>`).join('');
      results.querySelectorAll('.search-result').forEach((el) => el.addEventListener('click', () => {
        const r = list[Number(el.dataset.i)];
        $('search-modal').close();
        selectTopic(r.topic, { messageId: r.id });
      }));
    } catch (e) {
      summary.textContent = '';
      results.innerHTML = MS.empty('exclamation-triangle', `Search failed: ${e.message}`, null, false);
    }
  }

  // ─── Range / pause ──────────────────────────────────────
  const toLocalInput = (ms) => {
    const d = new Date(ms - new Date(ms).getTimezoneOffset() * 60000);
    return d.toISOString().slice(0, 16);
  };

  function applyRange() {
    MS.save('ms.range', S.range);
    $('custom-range').hidden = S.range !== 'custom';
    loadHistory({ keepSelection: true });
    if (S.tab === 'chart') renderChart();
  }

  function togglePause() {
    S.paused = !S.paused;
    const btn = $('pause-btn');
    btn.setAttribute('aria-pressed', S.paused);
    if (S.paused) btn.dataset.tone = 'warning'; else delete btn.dataset.tone;
    btn.innerHTML = S.paused ? MS.icon('play-fill') + '<span>Resume</span>' : MS.icon('pause-fill') + '<span>Pause</span>';
    btn.title = S.paused ? 'Resume live updates' : 'Pause live updates';
    if (!S.paused && S.missed) loadHistory({ keepSelection: true });
    S.missed = 0;
    renderTimelineStatus();
  }

  // ─── Live events ────────────────────────────────────────
  function onMessage(d) {
    if (!d || !d.topic) return;
    let e = S.topics.get(d.topic);
    const isNew = !e;
    e = e || upsertTopic(d);
    if (e) {
      e.count++;
      e.hits++;
      e.retained = !!d.retained;
      e.last_seen_ms = d.ts_ms;
      if (!e.first_seen_ms) e.first_seen_ms = d.ts_ms;
      e.last_size = d.size;
      e.preview = treePreview(d.payload, d.binary);
      if (d.stored && e.stored !== null && e.stored !== undefined) e.stored++;
      if (isNew) scheduleTree();
      else pulse(d.topic);
    }
    if (d.topic !== S.selected) return;
    if (S.paused || !bounds().live) { if (S.paused) { S.missed++; renderTimelineStatus(); } return; }
    const m = norm(d, true);
    queueLive(m);
    chartLive(m);
  }

  function onTopic(d) {
    if (!d || !d.topic || S.topics.has(d.topic)) return;
    const e = upsertTopic(d);
    if (e) { e.first_seen_ms = d.first_seen_ms ?? null; scheduleTree(); }
  }

  async function loadTopics() {
    try {
      const res = await MS.getJSON('/api/topics');
      loadTopicList(res.topics);
    } catch (e) {
      $('tree').innerHTML = MS.empty('exclamation-triangle', `Could not load topics: ${e.message}`);
      $('topic-count').textContent = 'Topics unavailable';
      return false;
    }
    renderTree();
    return true;
  }

  async function loadSettings() {
    try {
      const { settings } = await MS.getJSON('/api/settings');
      S.publishEnabled = String(settings.publish_enabled) !== 'false';
      S.dedup = String(settings.dedup_enabled) !== 'false';
      S.rateWindowS = Number(settings.rate_window_s) || S.rateWindowS;
      S.maxTopics = Number(settings.max_topics) || S.maxTopics;
      S.pageSize = Number(settings.history_default_limit) || S.pageSize;
    } catch {
      S.publishEnabled = true;
    }
    $('publish-btn').hidden = !S.publishEnabled;
  }

  // ─── Wiring ─────────────────────────────────────────────
  function wire() {
    $('tree').addEventListener('click', (ev) => {
      const row = ev.target.closest('.tree-row');
      if (!row) return;
      const path = row.dataset.path;
      const toggle = ev.target.closest('.tree-toggle');
      const folder = row.classList.contains('is-folder');
      if (folder && (toggle || !row.dataset.topic)) {
        if (S.filter) return;
        const node = { path, depth: path.split('/').length - 1 };
        setOpen(path, !isOpen(node));
        renderTree();
        return;
      }
      if (row.dataset.topic) selectTopic(row.dataset.topic);
    });
    $('tree').addEventListener('dblclick', (ev) => {
      const row = ev.target.closest('.tree-row.is-folder[data-topic]');
      if (!row || S.filter) return;
      const path = row.dataset.path;
      setOpen(path, !isOpen({ path, depth: path.split('/').length - 1 }));
      renderTree();
    });

    let filterTimer = null;
    $('topic-filter').addEventListener('input', (ev) => {
      clearTimeout(filterTimer);
      filterTimer = setTimeout(() => { S.filter = ev.target.value; renderTree(); }, 150);
    });
    $('tree-collapse').addEventListener('click', () => {
      const root = buildTree([...S.topics.values()]);
      const walk = (node) => node.children.forEach((c) => { if (c.children.size) { S.open[c.path] = false; walk(c); } });
      walk(root);
      setOpen('$SYS', false);
      renderTree();
    });

    $('timeline').addEventListener('click', (ev) => {
      const row = ev.target.closest('.tl-row');
      if (row) selectMessage(S.byKey.get(row.dataset.key) || null);
    });
    $('load-more').addEventListener('click', (ev) => loadMore(ev.currentTarget));

    // Tailor.tabs owns click/keyboard on the tab list and emits t:change; keep our state in sync.
    document.querySelector('.pane-tabs').addEventListener('t:change', (ev) => { if (ev.detail?.tab) showTab(ev.detail.tab.dataset.tab); });
    $('chart-path').addEventListener('change', (ev) => {
      if (S.selected) { S.chartPathByTopic[S.selected] = ev.target.value; MS.save('ms.chartPath', S.chartPathByTopic); }
      renderChart();
    });
    $('chart-reload').addEventListener('click', () => renderChart(true));
    $('copy-btn').addEventListener('click', async () => {
      const m = S.selectedMsg;
      if (!m || m.binary) return;
      try { await navigator.clipboard.writeText(m.payload || ''); MS.toast('success', 'Payload copied'); } catch (e) { MS.toast('error', `Copy failed: ${e.message}`); }
    });

    const range = $('range');
    if (!RANGES[S.range]) S.range = '1h';
    range.value = S.range;
    range.addEventListener('change', () => {
      if (range.value === 'custom') {
        $('custom-range').hidden = false;
        const b = bounds();
        $('range-from').value = toLocalInput(b.from_ms);
        $('range-to').value = toLocalInput(Date.now());
        return;
      }
      S.range = range.value;
      applyRange();
    });
    $('range-apply').addEventListener('click', () => {
      const from = Date.parse($('range-from').value);
      const to = $('range-to').value ? Date.parse($('range-to').value) : null;
      if (!Number.isFinite(from)) { MS.toast('warning', 'Pick a start time'); return; }
      if (to !== null && to <= from) { MS.toast('warning', 'End must be after start'); return; }
      S.custom = { from, to };
      S.range = 'custom';
      applyRange();
    });
    $('pause-btn').addEventListener('click', togglePause);

    $('publish-btn').addEventListener('click', openPublish);
    $('publish-form').addEventListener('submit', submitPublish);
    ['pub-topic', 'pub-payload', 'pub-retain', 'pub-qos'].forEach((id) => $(id).addEventListener('input', () => { resetPublishConfirm(); if (id === 'pub-payload') payloadHint(); }));
    $('publish-modal').addEventListener('close', resetPublishConfirm);
    $('search-form').addEventListener('submit', runSearch);

    setInterval(() => {
      tickRates();
      refreshVisibleRows();
      renderTimelineHead();
    }, TICK_MS);
  }

  async function boot() {
    wire();
    renderTimelineHead();
    timelineEmpty();
    renderMeta();
    renderPayload();
    await Promise.all([loadSettings(), loadTopics()]);

    const hash = new URLSearchParams(location.hash.slice(1));
    const initial = hash.get('topic') || MS.load('ms.selected', null);
    if (initial) selectTopic(initial);

    MS.stream(['#', '$SYS/#'], {
      message: onMessage,
      topic: onTopic,
      open: (reopened) => {
        if (!reopened) return;
        loadTopics();
        if (S.selected && !S.paused) loadHistory({ keepSelection: true });
      }
    });
  }

  document.addEventListener('DOMContentLoaded', boot);
})();
