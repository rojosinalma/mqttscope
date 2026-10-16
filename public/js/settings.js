/* Settings: sidebar tabs, per-tab save of changed keys, rule table editors. */
(function () {
  'use strict';

  const { esc } = MS;
  const $ = (id) => document.getElementById(id);
  const GIB = 1024 ** 3;
  const MASK = '••••';

  const RULE_COLUMNS = {
    sample_rules: [
      { key: 'pattern', label: 'Topic filter', type: 'text', placeholder: 'esp32/+/data', required: true },
      { key: 'min_interval_ms', label: 'Min interval (ms)', type: 'int', placeholder: '10000', required: true }
    ],
    presence_rules: [
      { key: 'name', label: 'Name', type: 'text', placeholder: 'esp32', required: true },
      { key: 'pattern', label: 'Topic filter', type: 'text', placeholder: 'esp32/+/status', required: true },
      { key: 'id_segment', label: 'ID segment', type: 'int', placeholder: '1', required: true },
      { key: 'online_path', label: 'Online path', type: 'text', placeholder: 'online' },
      { key: 'label_path', label: 'Label path', type: 'text', placeholder: 'hostname' },
      { key: 'stale_s', label: 'Stale (s)', type: 'int', placeholder: '90', required: true }
    ]
  };

  const state = { baseline: {} };

  // ─── Rule editors ───────────────────────────────────────
  function parseRules(raw) {
    if (Array.isArray(raw)) return raw;
    try { const v = JSON.parse(raw || '[]'); return Array.isArray(v) ? v : []; } catch { return []; }
  }

  function ruleRowHTML(cols, rule) {
    return `<tr>${cols.map((c) => `<td><input class="t-input t-mono${c.type === 'int' ? ' rule-num' : ''}" data-size="sm" type="${c.type === 'int' ? 'number' : 'text'}"`
      + ` data-col="${c.key}" value="${esc(rule[c.key] ?? '')}" placeholder="${esc(c.placeholder || '')}" aria-label="${esc(c.label)}"></td>`).join('')}`
      + '<td class="t-col-actions">'
      + '<button class="t-btn" data-variant="ghost" data-size="sm" data-icon="only" type="button" data-move="-1" title="Move up" aria-label="Move up">' + MS.icon('arrow-up') + '</button>'
      + '<button class="t-btn" data-variant="ghost" data-size="sm" data-icon="only" type="button" data-move="1" title="Move down" aria-label="Move down">' + MS.icon('arrow-down') + '</button>'
      + '<button class="t-btn" data-variant="ghost" data-size="sm" data-icon="only" data-tone="danger" type="button" data-remove title="Remove" aria-label="Remove">' + MS.icon('trash') + '</button></td></tr>';
  }

  function renderRules(editor, rules) {
    const cols = RULE_COLUMNS[editor.dataset.key];
    editor.innerHTML = `<table class="t-table rules-table" data-density="compact"><thead><tr>${cols.map((c) => `<th>${esc(c.label)}</th>`).join('')}<th class="t-col-actions"></th></tr></thead>`
      + `<tbody>${rules.map((r) => ruleRowHTML(cols, r)).join('')}</tbody></table>`
      + `<div class="rules-empty"${rules.length ? ' hidden' : ''}>No rules.</div>`
      + '<button class="t-btn" data-size="sm" type="button" data-add>' + MS.icon('plus-lg') + 'Add rule</button>';
  }

  function syncRulesEmpty(editor) {
    editor.querySelector('.rules-empty').hidden = editor.querySelectorAll('tbody tr').length > 0;
  }

  // Returns {value: JSON string} or {error}.
  function serializeRules(editor) {
    const cols = RULE_COLUMNS[editor.dataset.key];
    const rules = [];
    const rows = [...editor.querySelectorAll('tbody tr')];
    for (let i = 0; i < rows.length; i++) {
      const rule = {};
      let filled = false;
      for (const c of cols) {
        const raw = rows[i].querySelector(`[data-col="${c.key}"]`).value.trim();
        if (raw !== '') filled = true;
        if (raw === '') {
          if (c.required) rule.__missing = c.label;
          continue;
        }
        if (c.type === 'int') {
          if (!/^-?\d+$/.test(raw)) return { error: `Rule ${i + 1}: ${c.label} must be a whole number` };
          rule[c.key] = Number(raw);
        } else {
          rule[c.key] = raw;
        }
      }
      if (!filled) continue;
      if (rule.__missing) return { error: `Rule ${i + 1}: ${rule.__missing} is required` };
      rules.push(rule);
    }
    return { value: JSON.stringify(rules) };
  }

  function wireRules(editor) {
    editor.addEventListener('click', (ev) => {
      const cols = RULE_COLUMNS[editor.dataset.key];
      const tbody = editor.querySelector('tbody');
      if (ev.target.closest('[data-add]')) {
        tbody.insertAdjacentHTML('beforeend', ruleRowHTML(cols, {}));
        tbody.lastElementChild.querySelector('input')?.focus();
      } else if (ev.target.closest('[data-remove]')) {
        ev.target.closest('tr').remove();
      } else {
        const mv = ev.target.closest('[data-move]');
        if (!mv) return;
        const tr = mv.closest('tr');
        if (mv.dataset.move === '-1' && tr.previousElementSibling) tr.parentNode.insertBefore(tr, tr.previousElementSibling);
        if (mv.dataset.move === '1' && tr.nextElementSibling) tr.parentNode.insertBefore(tr.nextElementSibling, tr);
      }
      syncRulesEmpty(editor);
    });
  }

  // ─── Fields ─────────────────────────────────────────────
  function fill(settings) {
    document.querySelectorAll('[data-key]').forEach((el) => {
      const key = el.dataset.key;
      const raw = settings[key];
      if (raw === undefined) return;
      const v = String(raw);
      switch (el.dataset.kind) {
        case 'bool': el.checked = v === 'true'; break;
        case 'gb': el.value = String(Math.round((Number(v) / GIB) * 100) / 100); break;
        case 'rules': renderRules(el, parseRules(raw)); break;
        default: el.value = v;
      }
      state.baseline[key] = el.dataset.kind === 'rules' ? serializeRules(el).value : readField(el).value;
    });
  }

  // Returns {value} (string as stored) or {error}.
  function readField(el) {
    const label = el.closest('.t-field')?.querySelector('.t-label, .t-check-label')?.textContent?.trim() || el.dataset.key;
    switch (el.dataset.kind) {
      case 'bool': return { value: el.checked ? 'true' : 'false' };
      case 'rules': return serializeRules(el);
      case 'int': {
        const v = el.value.trim();
        if (!/^\d+$/.test(v)) return { error: `${label} must be a whole number` };
        const min = Number(el.min);
        if (el.min !== '' && Number(v) < min) return { error: `${label} must be at least ${min}` };
        return { value: String(Number(v)) };
      }
      case 'gb': {
        const n = Number(el.value);
        if (!Number.isFinite(n) || n <= 0) return { error: `${label} must be a positive number of GB` };
        return { value: String(Math.round(n * GIB)) };
      }
      case 'secret': return { value: el.value };
      default: return { value: el.value.trim() };
    }
  }

  async function savePane(form) {
    const changes = {};
    for (const el of form.querySelectorAll('[data-key]')) {
      const r = readField(el);
      if (r.error) { MS.toast('error', r.error); el.focus?.(); return; }
      if (r.value !== state.baseline[el.dataset.key]) changes[el.dataset.key] = r.value;
    }
    if (!Object.keys(changes).length) { MS.toast('warning', 'Nothing changed'); return; }
    const btn = form.querySelector('[type="submit"]');
    await MS.busy(btn, async () => {
      const res = await MS.postAction('/api/settings', changes);
      MS.toastResult(res);
      if (!res.ok) return;
      Object.entries(changes).forEach(([k, v]) => { state.baseline[k] = v; });
      if ('mqtt_pass' in changes) {
        const pass = form.querySelector('[data-key="mqtt_pass"]');
        const masked = changes.mqtt_pass === '' ? '' : MASK;
        pass.value = masked;
        state.baseline.mqtt_pass = masked;
      }
      if ('publish_enabled' in changes || 'dedup_enabled' in changes) { /* explorer reads these on load */ }
    });
  }

  function showPane(id) {
    const panes = [...document.querySelectorAll('.settings-pane')];
    if (!panes.some((p) => p.dataset.pane === id)) id = panes[0].dataset.pane;
    panes.forEach((p) => { p.hidden = p.dataset.pane !== id; });
    document.querySelectorAll('.settings-sidebar .t-sidebar-item').forEach((b) => {
      if (b.dataset.pane === id) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
    });
    history.replaceState(null, '', `#${id}`);
  }

  async function load() {
    try {
      const { settings } = await MS.getJSON('/api/settings');
      fill(settings || {});
      $('settings-error').hidden = true;
    } catch (e) {
      const box = $('settings-error');
      box.hidden = false;
      box.innerHTML = `<div class="t-alert" data-tone="danger" role="alert">${MS.icon('exclamation-triangle', 't-alert-icon')}<div class="t-alert-body">Could not load settings: ${esc(e.message)}</div></div>`;
      document.querySelectorAll('.settings-pane [type="submit"]').forEach((b) => { b.disabled = true; });
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('.rules-editor').forEach((ed) => { renderRules(ed, []); wireRules(ed); });
    document.querySelectorAll('.settings-sidebar .t-sidebar-item').forEach((b) => b.addEventListener('click', () => showPane(b.dataset.pane)));
    showPane(location.hash.slice(1));

    document.querySelectorAll('.settings-pane').forEach((form) => form.addEventListener('submit', (ev) => { ev.preventDefault(); savePane(form); }));

    document.querySelectorAll('.secret-toggle').forEach((btn) => btn.addEventListener('click', () => {
      const input = $(btn.dataset.target);
      const show = input.type === 'password';
      input.type = show ? 'text' : 'password';
      btn.innerHTML = MS.icon(show ? 'eye-slash' : 'eye');
    }));
    document.querySelectorAll('[data-kind="secret"]').forEach((el) => el.addEventListener('focus', () => { if (el.value === MASK) el.select(); }));

    $('reconnect-btn')?.addEventListener('click', (ev) =>
      MS.busy(ev.currentTarget, async () => MS.toastResult(await MS.postAction('/api/reconnect'))));

    const cap = $('local-timeline-cap');
    cap.value = String(MS.load('ms.timelineCap', 500));
    cap.addEventListener('change', () => {
      const n = Number(cap.value);
      if (!Number.isInteger(n) || n < 50 || n > 5000) { MS.toast('error', 'Timeline rows must be a whole number between 50 and 5000'); return; }
      MS.save('ms.timelineCap', n);
      MS.toast('success', `Explorer keeps ${n} live rows in this browser`);
    });

    load();
  });
})();
