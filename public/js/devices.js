/* Devices: presence table + online/offline timeline bar. */
(function () {
  'use strict';

  const { esc } = MS;
  const $ = (id) => document.getElementById(id);
  const RANGES = { '1h': 3600e3, '6h': 6 * 3600e3, '24h': 24 * 3600e3, '7d': 7 * 24 * 3600e3 };
  const FIELD_VALUE_MAX = 300;

  const state = {
    devices: [],
    filter: '',
    expanded: new Set(MS.load('ms.devices.expanded', [])),
    selected: MS.load('ms.devices.selected', null),
    range: MS.load('ms.devices.range', '24h'),
    loadedOnce: false
  };
  if (!RANGES[state.range]) state.range = '24h';

  const keyOf = (d) => `${d.name}:${d.id}`;

  function statusOf(d) {
    if (d.online) return { status: 'running', text: 'online' };
    if (d.stale) return { status: 'degraded', text: 'stale' };
    return { status: 'stopped', text: 'offline' };
  }

  function fieldsHTML(fields) {
    const entries = Object.entries(fields || {});
    if (!entries.length) return '<div class="t-small t-muted">No fields in the last payload.</div>';
    return `<div class="fields-grid">${entries.map(([k, v]) => {
      let s = typeof v === 'string' ? v : JSON.stringify(v);
      if (s && s.length > FIELD_VALUE_MAX) s = `${s.slice(0, FIELD_VALUE_MAX)}…`;
      return `<div><span class="f-key">${esc(k)}</span><span class="f-val">${esc(s)}</span></div>`;
    }).join('')}</div>`;
  }

  function matches(d) {
    if (!state.filter) return true;
    const f = state.filter.toLowerCase();
    return [d.label, d.id, d.name, d.topic].some((v) => String(v ?? '').toLowerCase().includes(f));
  }

  function render() {
    const list = state.devices.filter(matches);
    const online = state.devices.filter((d) => d.online).length;
    $('device-count').textContent = state.devices.length ? `${online} of ${state.devices.length} online` : '';

    const empty = $('devices-empty');
    const wrap = $('devices-wrap');
    if (!state.devices.length || !list.length) {
      wrap.hidden = true;
      empty.hidden = false;
      empty.innerHTML = state.devices.length
        ? MS.empty('bi-funnel', 'No devices match the filter.', null, false)
        : MS.empty('bi-cpu', 'No devices detected yet.', 'Devices come from the presence rules in Settings → Presence, matched against live topics.', false);
      return;
    }
    empty.hidden = true;
    wrap.hidden = false;

    $('devices-body').innerHTML = list.map((d) => {
      const k = keyOf(d);
      const st = statusOf(d);
      const open = state.expanded.has(k);
      const sel = state.selected && state.selected.key === k;
      const row = `<tr class="device-row" data-key="${esc(k)}" aria-selected="${sel}">`
        + `<td class="t-col-icon"><span class="t-dot" data-status="${st.status}" title="${st.text}"></span></td>`
        + `<td><div class="device-label">${esc(d.label || d.id)}</div><div class="device-topic">${esc(d.topic)}</div></td>`
        + `<td class="t-mono">${esc(d.id)}</td>`
        + `<td><span class="t-badge" data-tone="purple">${esc(d.name)}</span></td>`
        + `<td title="${esc(MS.fmtISO(d.last_seen_ms))}">${esc(MS.fmtRel(d.last_seen_ms))}</td>`
        + `<td title="${esc(MS.fmtISO(d.since_ms))}">${esc(d.since_ms ? MS.fmtRel(d.since_ms) : '—')}</td>`
        + `<td class="t-col-icon">${d.stale ? '<span class="t-badge" data-tone="orange" title="Not seen within the rule\'s stale_s">stale</span>' : `<span class="t-badge" data-tone="${d.online ? 'success' : 'danger'}">${st.text}</span>`}</td>`
        + `<td class="t-col-icon"><button class="t-btn expand-btn" data-variant="ghost" data-size="sm" data-icon="only" type="button" data-expand="${esc(k)}" aria-expanded="${open}" title="Show fields" aria-label="Show fields"><i class="bi bi-chevron-right"></i></button></td>`
        + '</tr>';
      const fields = open ? `<tr class="fields-row"><td colspan="8">${fieldsHTML(d.fields)}</td></tr>` : '';
      return row + fields;
    }).join('');
  }

  async function loadDevices() {
    try {
      const res = await MS.getJSON('/api/devices');
      state.devices = (res.devices || []).slice().sort((a, b) =>
        (b.online - a.online) || String(a.label || a.id).localeCompare(String(b.label || b.id), undefined, { numeric: true }));
      state.loadedOnce = true;
      render();
      if (state.selected && !state.devices.some((d) => keyOf(d) === state.selected.key)) closeTimeline();
    } catch (e) {
      if (!state.loadedOnce) {
        $('devices-wrap').hidden = true;
        $('devices-empty').hidden = false;
        $('devices-empty').innerHTML = MS.empty('bi-exclamation-triangle', `Could not load devices: ${e.message}`, null, false);
      } else {
        MS.toast('error', `Could not refresh devices: ${e.message}`);
      }
    }
  }

  // ─── Timeline ───────────────────────────────────────────
  function closeTimeline() {
    state.selected = null;
    MS.save('ms.devices.selected', null);
    $('timeline-card').hidden = true;
    render();
  }

  function segmentsFor(timeline, from, to) {
    const segs = [];
    let cursor = from;
    (timeline || []).forEach((t) => {
      const a = Math.max(from, t.from_ms);
      const b = Math.min(to, t.to_ms ?? to);
      if (b <= a) return;
      if (a > cursor) segs.push({ from: cursor, to: a, kind: 'none' });
      segs.push({ from: a, to: b, kind: t.online ? 'on' : 'off' });
      cursor = Math.max(cursor, b);
    });
    if (cursor < to) segs.push({ from: cursor, to, kind: 'none' });
    return segs;
  }

  async function loadTimeline() {
    const sel = state.selected;
    if (!sel) return;
    $('timeline-card').hidden = false;
    $('timeline-title').textContent = `${sel.label} · timeline`;
    $('timeline-range').value = state.range;
    const to = Date.now();
    const from = to - RANGES[state.range];
    try {
      const res = await MS.getJSON(`/api/devices/${encodeURIComponent(sel.id)}/timeline${MS.qs({ from_ms: from, to_ms: to })}`);
      if (state.selected !== sel) return;
      const segs = segmentsFor(res.timeline, from, to);
      const known = segs.filter((s) => s.kind !== 'none');
      if (!known.length) {
        $('timeline-wrap').hidden = true;
        $('timeline-empty').hidden = false;
        $('timeline-empty').innerHTML = MS.empty('bi-bar-chart-steps', 'No presence history in this range.', 'History builds from stored status messages.');
        $('timeline-uptime').textContent = '';
        return;
      }
      $('timeline-empty').hidden = true;
      $('timeline-wrap').hidden = false;
      const bar = $('timeline-bar');
      bar.innerHTML = '';
      segs.forEach((s) => {
        const el = document.createElement('div');
        el.className = `uptime-seg ${s.kind}`;
        el.style.flexGrow = String(s.to - s.from);
        const label = s.kind === 'on' ? 'online' : s.kind === 'off' ? 'offline' : 'no data';
        el.title = `${label}: ${MS.fmtISO(s.from)} → ${MS.fmtISO(s.to)} (${MS.fmtDuration((s.to - s.from) / 1000)})`;
        bar.appendChild(el);
      });
      $('timeline-from').textContent = MS.fmtDateTime(from);
      $('timeline-to').textContent = 'now';
      const onMs = known.filter((s) => s.kind === 'on').reduce((a, s) => a + (s.to - s.from), 0);
      const knownMs = known.reduce((a, s) => a + (s.to - s.from), 0);
      const flips = known.filter((s) => s.kind === 'off').length;
      $('timeline-uptime').textContent = `${((onMs / knownMs) * 100).toFixed(1)} % online · ${flips} offline period${flips === 1 ? '' : 's'}`;
    } catch (e) {
      $('timeline-wrap').hidden = true;
      $('timeline-empty').hidden = false;
      $('timeline-empty').innerHTML = MS.empty('bi-exclamation-triangle', `Could not load the timeline: ${e.message}`);
    }
  }

  document.addEventListener('DOMContentLoaded', async () => {
    $('devices-body').addEventListener('click', (ev) => {
      const exp = ev.target.closest('[data-expand]');
      if (exp) {
        ev.stopPropagation();
        const k = exp.dataset.expand;
        if (state.expanded.has(k)) state.expanded.delete(k); else state.expanded.add(k);
        MS.save('ms.devices.expanded', [...state.expanded].slice(-200));
        render();
        return;
      }
      const row = ev.target.closest('.device-row');
      if (!row) return;
      const d = state.devices.find((x) => keyOf(x) === row.dataset.key);
      if (!d) return;
      state.selected = { key: keyOf(d), id: d.id, label: d.label || d.id };
      MS.save('ms.devices.selected', state.selected);
      render();
      loadTimeline();
      $('timeline-card').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    });

    let t = null;
    $('device-filter').addEventListener('input', (ev) => {
      clearTimeout(t);
      t = setTimeout(() => { state.filter = ev.target.value.trim(); render(); }, 120);
    });
    $('timeline-range').addEventListener('change', (ev) => {
      state.range = ev.target.value;
      MS.save('ms.devices.range', state.range);
      loadTimeline();
    });
    $('timeline-close').addEventListener('click', closeTimeline);

    await loadDevices();
    if (state.selected) loadTimeline();

    // Global stats events (≈10 s) drive the refresh; the filter keeps this stream near-silent.
    let n = 0;
    MS.stream(['$SYS/broker/uptime'], {
      stats: () => {
        loadDevices();
        if (state.selected && ++n % 6 === 0) loadTimeline();
      },
      open: (reopened) => { if (reopened) loadDevices(); }
    });
    setInterval(() => { if (!document.hidden) render(); }, 5000);
  });
})();
