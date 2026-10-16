/* mqttscope shared helpers: escaping, formatting, fetch, toasts (Tailor.toast), SSE stream, connection indicator, charts. */
(function () {
  'use strict';

  const MS = (window.MS = {});

  // ─── Escaping ───────────────────────────────────────────
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  MS.esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c]);

  // ─── Local storage (JSON, never throws) ─────────────────
  MS.load = (key, fallback) => {
    try { const v = localStorage.getItem(key); return v === null ? fallback : JSON.parse(v); } catch { return fallback; }
  };
  MS.save = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* quota */ } };

  // ─── Formatting ─────────────────────────────────────────
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

  MS.fmtClock = (ms, withMs = true) => {
    const d = new Date(ms);
    const t = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    return withMs ? `${t}.${pad(d.getMilliseconds(), 3)}` : t;
  };
  MS.fmtDay = (ms) => { const d = new Date(ms); return `${MONTHS[d.getMonth()]} ${pad(d.getDate())}`; };
  MS.isToday = (ms) => sameDay(new Date(ms), new Date());
  MS.fmtDateTime = (ms) => {
    if (ms === null || ms === undefined) return '—';
    return MS.isToday(ms) ? MS.fmtClock(ms, false) : `${MS.fmtDay(ms)} ${MS.fmtClock(ms, false)}`;
  };
  MS.fmtISO = (ms) => (ms === null || ms === undefined ? '' : new Date(ms).toLocaleString());

  MS.fmtDuration = (sec) => {
    sec = Math.max(0, Math.round(sec));
    if (sec < 60) return `${sec}s`;
    const m = Math.floor(sec / 60);
    if (m < 60) return `${m}m ${sec % 60}s`;
    const h = Math.floor(m / 60);
    if (h < 48) return `${h}h ${m % 60}m`;
    return `${Math.floor(h / 24)}d ${h % 24}h`;
  };
  MS.fmtRel = (ms) => {
    if (ms === null || ms === undefined) return '—';
    const diff = (Date.now() - ms) / 1000;
    if (Math.abs(diff) < 2) return 'just now';
    return diff >= 0 ? `${MS.fmtDuration(diff)} ago` : `in ${MS.fmtDuration(-diff)}`;
  };

  MS.fmtBytes = (n) => {
    n = Number(n);
    if (!Number.isFinite(n)) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    while (Math.abs(n) >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${i === 0 ? Math.round(n) : n.toFixed(n < 10 ? 2 : 1)} ${units[i]}`;
  };
  MS.fmtNum = (n, digits = 0) => {
    n = Number(n);
    if (!Number.isFinite(n)) return '—';
    return n.toLocaleString(undefined, { maximumFractionDigits: digits });
  };
  MS.fmtRate = (r) => {
    r = Number(r) || 0;
    if (r >= 100) return `${Math.round(r)}/s`;
    if (r >= 10) return `${r.toFixed(1)}/s`;
    if (r >= 0.1) return `${r.toFixed(2)}/s`;
    return `${(r * 60).toFixed(1)}/min`;
  };

  // ─── Toasts (Tailor.toast; queued until tailor.js is up) ─
  const TOAST_MS = 2500;
  const toastQueue = [];
  MS.toast = (type, msg) => {
    if (!window.Tailor) { toastQueue.push([type, msg]); return; }
    Tailor.toast(type === 'error' ? 'danger' : type, msg, { timeout: TOAST_MS });
  };
  const flushToasts = () => { while (window.Tailor && toastQueue.length) MS.toast(...toastQueue.shift()); };
  MS.toastResult = (res) => MS.toast(res.ok ? 'success' : 'error', res.message || (res.ok ? 'Done' : 'Failed'));

  // ─── Fetch ──────────────────────────────────────────────
  MS.qs = (params) => {
    const q = new URLSearchParams();
    Object.entries(params || {}).forEach(([k, v]) => { if (v !== null && v !== undefined && v !== '') q.set(k, v); });
    const s = q.toString();
    return s ? `?${s}` : '';
  };

  async function parse(res, url) {
    let body;
    try { body = await res.json(); } catch { body = null; }
    if (!body || typeof body !== 'object') return { ok: false, status: res.status, message: `${res.status} ${res.statusText || 'error'} from ${url}` };
    if (body.ok === undefined) body.ok = res.ok;
    body.status = res.status;
    if (!body.message) body.message = res.ok ? 'OK' : `HTTP ${res.status}`;
    return body;
  }

  // GET returning the parsed {ok, message, ...}; throws an Error carrying the server's message when !ok.
  MS.getJSON = async (url, { signal } = {}) => {
    let res;
    try { res = await fetch(url, { headers: { Accept: 'application/json' }, signal }); } catch (e) {
      if (e.name === 'AbortError') throw e;
      throw new Error(`Request failed: ${e.message}`);
    }
    const body = await parse(res, url);
    if (!body.ok) { const err = new Error(body.message); err.status = body.status; throw err; }
    return body;
  };

  // POST action: always resolves to the server's {ok, message, ...}, never throws.
  MS.postAction = async (url, body) => {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(body || {})
      });
      return await parse(res, url);
    } catch (e) {
      return { ok: false, message: `Request failed: ${e.message}` };
    }
  };

  // Disable a button with a spinner while fn runs.
  MS.busy = async (btn, fn) => {
    if (!btn) return fn();
    const html = btn.innerHTML;
    btn.disabled = true;
    btn.setAttribute('aria-busy', 'true');
    btn.innerHTML = `<span class="t-spinner" data-size="sm" aria-hidden="true"></span>${html}`;
    try { return await fn(); } finally { btn.disabled = false; btn.removeAttribute('aria-busy'); btn.innerHTML = html; }
  };

  // Icon from the tailor sprite (public/tailor/icons.svg, Bootstrap Icons names without the bi- prefix); decorative.
  MS.icon = (name, cls = '') => `<svg class="t-icon${cls ? ' ' + cls : ''}" aria-hidden="true"><use href="/tailor/icons.svg#bi-${name}"/></svg>`;

  MS.empty = (icon, text, hint, compact = true) =>
    `<div class="t-empty"${compact ? ' data-size="sm"' : ''}>${MS.icon(icon, 't-empty-icon')}<div class="t-empty-title">${MS.esc(text)}</div>${hint ? `<p>${MS.esc(hint)}</p>` : ''}</div>`;
  MS.loading = () => '<div class="t-empty" data-size="sm"><span class="t-spinner" data-size="sm" role="status" aria-label="Loading"></span></div>';

  // ─── Theme (tailor owns skin/palette/mode; charts re-render when <html> data-* change) ──
  const TOKENS = { fg: 'text', comment: 'muted', selection: 'border', purple: 'hue-purple', green: 'hue-green', cyan: 'hue-cyan', orange: 'hue-orange', pink: 'hue-pink', red: 'hue-red', yellow: 'hue-yellow' };
  MS.color = (name) => {
    const css = getComputedStyle(document.documentElement);
    return css.getPropertyValue(`--t-${TOKENS[name] || name}`).trim() || css.getPropertyValue('--t-accent').trim();
  };
  new MutationObserver(() => document.dispatchEvent(new CustomEvent('ms:theme')))
    .observe(document.documentElement, { attributes: true, attributeFilter: ['data-skin', 'data-palette', 'data-mode'] });

  // ─── Broker connection indicator + banner ───────────────
  const conn = { broker: null, error: null, host: null, stream: 'idle' };
  MS.conn = conn;

  function renderConn() {
    const ind = document.getElementById('conn-indicator');
    if (!ind) return;
    const dot = ind.querySelector('.t-dot');
    const label = document.getElementById('conn-label');
    let status = 'muted';
    let text = 'broker';
    let title = 'Broker connection: unknown';
    if (conn.broker === true) {
      status = 'running'; text = 'connected';
      title = `Connected to ${conn.host || 'broker'}`;
    } else if (conn.broker === false) {
      status = 'stopped'; text = 'disconnected';
      title = `Disconnected from ${conn.host || 'broker'}${conn.error ? `: ${conn.error}` : ''}`;
    }
    if (conn.stream === 'lost' && conn.broker !== false) {
      status = 'degraded'; text = 'stream lost';
      title = 'Live stream to mqttscope interrupted; reconnecting…';
    }
    dot.dataset.status = status;
    label.textContent = text;
    ind.title = title;

    const banner = document.getElementById('conn-banner');
    if (banner) {
      banner.hidden = conn.broker !== false;
      const detail = document.getElementById('conn-banner-detail');
      detail.textContent = `${conn.host ? `${conn.host} · ` : ''}${conn.error ? `${conn.error}. ` : ''}Live data is paused; stored history is still available.`;
    }
  }

  MS.setConn = (connected, { error, host, port } = {}) => {
    if (typeof connected !== 'boolean') return;
    const changed = conn.broker !== connected;
    conn.broker = connected;
    conn.error = connected ? null : (error || conn.error);
    if (host) conn.host = port ? `${host}:${port}` : host;
    renderConn();
    if (changed) document.dispatchEvent(new CustomEvent('ms:conn', { detail: { connected } }));
  };
  MS.applyIngest = (ingest) => { if (ingest) MS.setConn(ingest.connected, ingest); };

  // ─── SSE stream ─────────────────────────────────────────
  const EVENT_TYPES = ['hello', 'message', 'topic', 'connection', 'stats', 'dropped', 'bye'];
  const HIDDEN_CLOSE_MS = 30000;
  const RETRY_S = [2, 5, 10, 30];

  // One EventSource per page. handlers: {message, topic, connection, stats, dropped, hello, open(reopened)}.
  MS.stream = (filters, handlers = {}) => {
    let es = null;
    let retries = 0;
    let retryTimer = null;
    let hideTimer = null;
    let opened = false;
    let lastDropToast = 0;
    const url = `/api/stream${MS.qs({ topics: (filters || ['#']).join(',') })}`;

    const internal = {
      hello: (d) => {
        if (typeof d.connected === 'boolean') MS.setConn(d.connected, d);
        else if (d.ingest) MS.applyIngest(d.ingest);
      },
      connection: (d) => MS.setConn(d.connected, d),
      stats: (d) => MS.applyIngest(d.ingest),
      dropped: (d) => {
        if (Date.now() - lastDropToast > 15000) {
          lastDropToast = Date.now();
          MS.toast('warning', `Live view fell behind: ${d.n} events dropped`);
        }
      }
    };

    function open() {
      clearTimeout(retryTimer);
      if (es) return;
      es = new EventSource(url);
      EVENT_TYPES.forEach((type) => {
        es.addEventListener(type, (e) => {
          let d;
          try { d = JSON.parse(e.data); } catch { return; }
          internal[type]?.(d);
          try { handlers[type]?.(d); } catch (err) { console.error(`[sse] ${type} handler`, err); }
        });
      });
      es.onopen = () => {
        retries = 0;
        conn.stream = 'live';
        renderConn();
        handlers.open?.(opened);
        opened = true;
      };
      es.onerror = () => {
        conn.stream = 'lost';
        renderConn();
        if (es && es.readyState === EventSource.CLOSED) {
          // Server refused or closed for good (e.g. sse_max_clients reached): retry with backoff ourselves.
          es = null;
          const wait = RETRY_S[Math.min(retries++, RETRY_S.length - 1)];
          retryTimer = setTimeout(open, wait * 1000);
        }
      };
    }

    function close() {
      clearTimeout(retryTimer);
      if (es) { es.close(); es = null; }
    }

    // Free the server slot when the tab is hidden for a while; reopen (and let the page refill) when back.
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        hideTimer = setTimeout(() => { close(); conn.stream = 'idle'; }, HIDDEN_CLOSE_MS);
      } else {
        clearTimeout(hideTimer);
        open();
      }
    });
    window.addEventListener('pagehide', close);

    open();
    return { close, open };
  };

  // ─── Charts (uPlot) ─────────────────────────────────────
  // points: [[ts_ms, value], ...] → uPlot columnar data with x in seconds.
  MS.toColumns = (points) => {
    const xs = [];
    const ys = [];
    (points || []).forEach(([t, v]) => {
      const n = Number(v);
      if (Number.isFinite(n)) { xs.push(t / 1000); ys.push(n); }
    });
    return [xs, ys];
  };

  // A themed line chart that resizes with its box and rebuilds on skin/palette/mode change.
  MS.chart = (el, { data, label = 'value', color = 'purple', height = 220, spark = false, fmt } = {}) => {
    if (!window.uPlot) {
      el.innerHTML = MS.empty('exclamation-triangle', 'Chart library failed to load (cdn.jsdelivr.net).');
      return { setData() {}, destroy() {} };
    }
    let plot = null;
    let current = data || [[], []];

    function opts() {
      const fg = MS.color('fg');
      const muted = MS.color('comment');
      const grid = MS.color('selection');
      const stroke = MS.color(color);
      const width = Math.max(120, el.clientWidth || 300);
      const axis = { stroke: muted, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 }, font: '11px ui-monospace, monospace' };
      return {
        width,
        height,
        legend: { show: !spark },
        cursor: spark ? { show: true, x: false, y: false, points: { size: 5 } } : { drag: { x: true, y: false } },
        scales: { x: { time: true } },
        axes: spark ? [{ show: false }, { show: false }] : [axis, { ...axis, size: 56, values: fmt ? (u, vals) => vals.map(fmt) : undefined }],
        series: [
          {},
          {
            label,
            stroke,
            width: spark ? 1.5 : 1.75,
            fill: `${stroke}22`,
            points: { show: false },
            value: (u, v) => (v === null || v === undefined ? '—' : fmt ? fmt(v) : MS.fmtNum(v, 3))
          }
        ],
        padding: spark ? [4, 2, 2, 2] : [8, 8, 0, 0],
        hooks: {}
      };
    }

    function build() {
      if (plot) plot.destroy();
      el.innerHTML = '';
      plot = new uPlot(opts(), current, el);
    }

    const ro = new ResizeObserver(() => { if (plot && el.clientWidth) plot.setSize({ width: el.clientWidth, height }); });
    ro.observe(el);
    const onTheme = () => build();
    document.addEventListener('ms:theme', onTheme);
    build();

    return {
      setData(d) { current = d; plot?.setData(d); },
      push(x, y, max) {
        current[0].push(x); current[1].push(y);
        if (max && current[0].length > max) { current[0].shift(); current[1].shift(); }
        plot?.setData(current);
      },
      get data() { return current; },
      destroy() { ro.disconnect(); document.removeEventListener('ms:theme', onTheme); plot?.destroy(); plot = null; el.innerHTML = ''; }
    };
  };

  // ─── Boot ───────────────────────────────────────────────
  document.addEventListener('DOMContentLoaded', () => {
    flushToasts();

    document.getElementById('conn-banner-reconnect')?.addEventListener('click', (e) =>
      MS.busy(e.currentTarget, async () => MS.toastResult(await MS.postAction('/api/reconnect')))
    );

    // `/` focuses the page's search/filter; Escape closes any open dialog (native dialogs do this themselves).
    document.addEventListener('keydown', (e) => {
      const tag = (e.target.tagName || '').toLowerCase();
      const typing = ['input', 'textarea', 'select'].includes(tag) || e.target.isContentEditable;
      if (e.key === '/' && !typing && !e.ctrlKey && !e.metaKey && !e.altKey) {
        const target = document.querySelector('[data-hotkey="/"]');
        if (target) { e.preventDefault(); target.focus(); target.select?.(); }
      } else if (e.key === 'Escape') {
        document.querySelectorAll('dialog[open]').forEach((d) => d.close());
        if (typing && e.target.matches('[data-hotkey="/"]')) e.target.blur();
      }
    });

    renderConn();
    MS.getJSON('/api/stats').then((r) => MS.applyIngest(r.ingest)).catch(() => {});
  });
})();
