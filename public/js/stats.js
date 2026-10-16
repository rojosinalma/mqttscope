/* Stats: ingest, database, broker $SYS readouts and sparklines. */
(function () {
  'use strict';

  const { esc } = MS;
  const $ = (id) => document.getElementById(id);
  const SYS = '$SYS/broker/';
  const SCALAR_PATH = '.';        // the payload itself; the API requires a non-empty path
  const SPARK_RANGE_MS = 24 * 3600e3;
  const SPARK_POINTS = 144;
  const SPARK_EVERY_N_STATS = 6;   // stats events arrive ≈10 s apart; $SYS is stored ≈60 s apart

  const num = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : null; };
  const F = {
    int: (v) => (num(v) === null ? String(v) : MS.fmtNum(num(v))),
    dec: (v) => (num(v) === null ? String(v) : MS.fmtNum(num(v), 2)),
    bytes: (v) => (num(v) === null ? String(v) : MS.fmtBytes(num(v))),
    bytesMin: (v) => (num(v) === null ? String(v) : `${MS.fmtBytes(num(v))}/min`),
    perMin: (v) => (num(v) === null ? String(v) : `${MS.fmtNum(num(v), 1)}/min`),
    uptime: (v) => (num(v) === null ? String(v) : MS.fmtDuration(num(v))),
    text: (v) => String(v)
  };

  const GROUPS = [
    { title: 'Clients', icon: 'people', rows: [
      ['clients/connected', 'Connected', F.int], ['clients/total', 'Total', F.int], ['clients/maximum', 'Maximum', F.int],
      ['clients/disconnected', 'Disconnected', F.int], ['clients/expired', 'Expired', F.int], ['clients/active', 'Active', F.int]
    ] },
    { title: 'Messages', icon: 'envelope', rows: [
      ['messages/received', 'Received', F.int], ['messages/sent', 'Sent', F.int], ['messages/stored', 'Stored', F.int],
      ['retained messages/count', 'Retained', F.int], ['store/messages/count', 'In store', F.int],
      ['publish/messages/dropped', 'Dropped', F.int], ['subscriptions/count', 'Subscriptions', F.int]
    ] },
    { title: 'Bytes', icon: 'hdd-network', rows: [
      ['bytes/received', 'Received', F.bytes], ['bytes/sent', 'Sent', F.bytes], ['store/messages/bytes', 'Store', F.bytes],
      ['publish/bytes/received', 'Publish in', F.bytes], ['publish/bytes/sent', 'Publish out', F.bytes]
    ] },
    { title: 'Load · 1 min', icon: 'activity', rows: [
      ['load/messages/received/1min', 'Messages in', F.perMin], ['load/messages/sent/1min', 'Messages out', F.perMin],
      ['load/publish/received/1min', 'Publish in', F.perMin], ['load/publish/sent/1min', 'Publish out', F.perMin],
      ['load/bytes/received/1min', 'Bytes in', F.bytesMin], ['load/bytes/sent/1min', 'Bytes out', F.bytesMin],
      ['load/connections/1min', 'Connections', F.perMin], ['load/sockets/1min', 'Sockets', F.perMin]
    ] },
    { title: 'Load · 15 min', icon: 'activity', rows: [
      ['load/messages/received/15min', 'Messages in', F.perMin], ['load/messages/sent/15min', 'Messages out', F.perMin],
      ['load/bytes/received/15min', 'Bytes in', F.bytesMin], ['load/bytes/sent/15min', 'Bytes out', F.bytesMin]
    ] },
    { title: 'Broker', icon: 'hdd-rack', rows: [
      ['version', 'Version', F.text], ['uptime', 'Uptime', F.uptime], ['heap/current', 'Heap', F.bytes], ['heap/maximum', 'Heap peak', F.bytes]
    ] }
  ];

  const SPARKS = [
    ['clients/connected', 'Clients connected', 'green', F.int],
    ['load/messages/received/1min', 'Messages in /min', 'cyan', F.dec],
    ['load/messages/sent/1min', 'Messages out /min', 'purple', F.dec],
    ['load/bytes/received/1min', 'Bytes in /min', 'orange', F.bytes]
  ];

  const state = { sys: {}, statsEvents: 0, sparks: new Map(), allOpen: false };

  function kv(rows) {
    return rows.map(([k, v, title]) => `<dt>${esc(k)}</dt><dd${title ? ` title="${esc(title)}"` : ''}>${v}</dd>`).join('');
  }

  // ─── Ingest ─────────────────────────────────────────────
  function renderIngest(ing, sseClients) {
    if (!ing) return;
    const badge = ing.connected
      ? '<span class="t-badge" data-tone="success"><span class="t-dot" data-status="running"></span> connected</span>'
      : '<span class="t-badge" data-tone="danger"><span class="t-dot" data-status="stopped"></span> disconnected</span>';
    $('ingest-badge').innerHTML = badge;
    const rows = [
      ['Broker', esc(`${ing.host ?? '—'}${ing.port ? `:${ing.port}` : ''}`)],
      [ing.connected ? 'Connected since' : 'Down since', esc(ing.since_ms ? MS.fmtRel(ing.since_ms) : '—'), MS.fmtISO(ing.since_ms)],
      ['Messages / s', esc(MS.fmtNum(ing.msgs_per_s, 2))],
      ['Bytes / s', esc(`${MS.fmtBytes(ing.bytes_per_s)}/s`)],
      ['Topics', esc(MS.fmtNum(ing.topics))],
      ['Messages total', esc(MS.fmtNum(ing.msgs_total))],
      ['Last message', esc(MS.fmtRel(ing.last_message_ms)), MS.fmtISO(ing.last_message_ms)]
    ];
    if (sseClients !== undefined) rows.push(['Live streams', esc(MS.fmtNum(sseClients))]);
    if (ing.error) rows.push(['Last error', `<span class="t-tone-text" data-tone="danger">${esc(ing.error)}</span>`]);
    $('ingest-kv').innerHTML = kv(rows);
  }

  // ─── Database ───────────────────────────────────────────
  function renderDb(db, prune) {
    if (!db) return;
    const pct = db.max_bytes ? Math.min(100, (db.size_bytes / db.max_bytes) * 100) : 0;
    const bar = $('db-size-bar');
    bar.style.setProperty('--t-value', `${pct.toFixed(1)}%`);
    bar.dataset.tone = pct >= 90 ? 'danger' : pct >= 70 ? 'warning' : 'success';
    bar.parentElement.setAttribute('aria-valuenow', Math.round(pct));
    $('db-size-label').textContent = `${MS.fmtBytes(db.size_bytes)} of ${MS.fmtBytes(db.max_bytes)}`;
    $('db-size-pct').textContent = `${pct < 1 ? pct.toFixed(2) : pct.toFixed(1)} %`;

    const gov = { retention: ['cyan', 'retention governs', 'Age limit is what deletes rows'],
                  size: ['orange', 'size governs', 'Size limit is what deletes rows'],
                  none: ['neutral', 'within limits', 'Neither limit has been reached'] }[db.governing] || ['neutral', db.governing || '—', ''];
    $('db-governing').innerHTML = `<span class="t-badge" data-tone="${gov[0]}" title="${esc(gov[2])}">${esc(gov[1])}</span>`;

    const rows = [
      ['Messages', esc(MS.fmtNum(db.messages))],
      ['Topics stored', esc(MS.fmtNum(db.topics))],
      ['Oldest', esc(db.oldest_ms ? MS.fmtRel(db.oldest_ms) : '—'), MS.fmtISO(db.oldest_ms)],
      ['Newest', esc(db.newest_ms ? MS.fmtRel(db.newest_ms) : '—'), MS.fmtISO(db.newest_ms)],
      ['Retention', esc(`${db.retention_days ?? '—'} days`)]
    ];
    if (prune) {
      const deleted = (prune.deleted_by_age || 0) + (prune.deleted_by_size || 0);
      rows.push(['Last prune', esc(prune.at_ms ? MS.fmtRel(prune.at_ms) : '—'), MS.fmtISO(prune.at_ms)]);
      rows.push(['Pruned', `${esc(MS.fmtNum(deleted))} <span class="t-stat-sub">(${esc(MS.fmtNum(prune.deleted_by_age || 0))} age · ${esc(MS.fmtNum(prune.deleted_by_size || 0))} size · ${esc(MS.fmtNum(prune.duration_s, 2))} s)</span>`]);
    } else {
      rows.push(['Last prune', '<span class="t-stat-sub">not yet run</span>']);
    }
    $('db-kv').innerHTML = kv(rows);
  }

  // ─── $SYS ───────────────────────────────────────────────
  function renderSys() {
    const sys = state.sys;
    const keys = Object.keys(sys);
    $('sys-empty').hidden = keys.length > 0;
    $('sys-groups').hidden = !keys.length;
    if (!keys.length) {
      $('sys-empty').innerHTML = `<div class="t-card">${MS.empty('hdd-rack', 'No $SYS data stored yet.', 'Needs $SYS/# in the broker subscriptions; values are sampled about once a minute.', false)}</div>`;
    }
    $('sys-groups').innerHTML = GROUPS.map((g) => {
      const rows = g.rows.filter(([k]) => sys[SYS + k] !== undefined).map(([k, label, fmt]) => [label, esc(fmt(sys[SYS + k])), SYS + k]);
      if (!rows.length) return '';
      return `<div class="t-card"><div class="t-card-header"><h3 class="t-card-title">${MS.icon(g.icon)}${esc(g.title)}</h3></div>`
        + `<div class="t-card-body"><dl class="kv">${kv(rows)}</dl></div></div>`;
    }).join('');

    $('sys-all-count').textContent = keys.length ? `${MS.fmtNum(keys.length)} topics` : '';
    if (state.allOpen) renderSysAll();
  }

  function renderSysAll() {
    const keys = Object.keys(state.sys).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    $('sys-all-body').innerHTML = keys.length
      ? keys.map((k) => `<tr><td class="t-mono t-small">${esc(k)}</td><td class="t-mono t-small t-col-num">${esc(String(state.sys[k]).slice(0, 200))}</td></tr>`).join('')
      : `<tr><td colspan="2">${MS.empty('inbox', 'No $SYS topics yet.')}</td></tr>`;
  }

  // ─── Sparklines ─────────────────────────────────────────
  function buildSparkCards() {
    $('sparks').innerHTML = SPARKS.map(([k, label], i) => `<div class="t-card spark-card" data-variant="stat">`
      + `<div class="spark-head"><span class="t-stat-label">${esc(label)}</span><span class="t-stat-value" id="spark-now-${i}">—</span></div>`
      + `<div class="t-stat-box spark-box" id="spark-${i}"></div></div>`).join('');
  }

  async function loadSparks() {
    const to = Date.now();
    await Promise.all(SPARKS.map(async ([k, label, color, fmt], i) => {
      const box = $(`spark-${i}`);
      try {
        const res = await MS.getJSON(`/api/stats/series${MS.qs({ topic: SYS + k, path: SCALAR_PATH, from_ms: to - SPARK_RANGE_MS, to_ms: to, max_points: SPARK_POINTS })}`);
        const data = MS.toColumns(res.points);
        const last = data[1].length ? data[1][data[1].length - 1] : null;
        $(`spark-now-${i}`).textContent = last === null ? '—' : fmt(last);
        const existing = state.sparks.get(i);
        if (!data[0].length) {
          existing?.destroy();
          state.sparks.delete(i);
          box.innerHTML = '<div class="spark-empty">no samples yet</div>';
          return;
        }
        if (existing) existing.setData(data);
        else state.sparks.set(i, MS.chart(box, { data, label, color, height: 56, spark: true, fmt }));
      } catch (e) {
        box.innerHTML = `<div class="spark-empty">${esc(e.message)}</div>`;
      }
    }));
  }

  // ─── Load / refresh ─────────────────────────────────────
  async function refresh() {
    try {
      const r = await MS.getJSON('/api/stats');
      MS.applyIngest(r.ingest);
      renderIngest(r.ingest, r.sse_clients);
      renderDb(r.db, r.prune);
      state.sys = r.sys || {};
      renderSys();
      $('stats-updated').textContent = `Updated ${MS.fmtClock(Date.now(), false)}`;
    } catch (e) {
      $('stats-updated').textContent = `Update failed: ${e.message}`;
    }
  }

  async function prune(btn) {
    await MS.busy(btn, async () => {
      const res = await MS.postAction('/api/prune');
      if (res.ok && res.prune) {
        const p = res.prune;
        MS.toast('success', `${res.message} in ${MS.fmtNum(p.duration_s, 2)} s · ${MS.fmtBytes(p.size_before)} → ${MS.fmtBytes(p.size_after)}`);
      } else if (res.ok) {
        MS.toast('warning', res.message);
      } else {
        MS.toastResult(res);
      }
      await refresh();
    });
  }

  document.addEventListener('DOMContentLoaded', () => {
    buildSparkCards();
    refresh();
    loadSparks();
    $('prune-btn').addEventListener('click', (e) => prune(e.currentTarget));
    $('sys-all-card').addEventListener('toggle', (e) => {
      state.allOpen = e.currentTarget.open;
      if (state.allOpen) renderSysAll();
    });

    let sysTimer = null;
    MS.stream(['$SYS/#'], {
      stats: (d) => {
        renderIngest(d.ingest);
        state.statsEvents++;
        refresh();
        if (state.statsEvents % SPARK_EVERY_N_STATS === 0) loadSparks();
      },
      message: (d) => {
        if (!d.topic || !d.topic.startsWith('$SYS/') || d.payload === null || d.payload === undefined) return;
        state.sys[d.topic] = d.payload;
        if (!sysTimer) sysTimer = setTimeout(() => { sysTimer = null; renderSys(); }, 1000);
      },
      open: (reopened) => { if (reopened) { refresh(); loadSparks(); } }
    });

    // Relative times ("12s ago") stay current between refreshes.
    setInterval(() => { if (!document.hidden) refresh(); }, 30000);
  });
})();
