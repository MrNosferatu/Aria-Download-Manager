/* Aria Download Manager — the extension's manager page, driven by the manager's live
   state stream. */
'use strict';

const S = {
  state: null,
  filter: 'all',
  search: '',
  expanded: new Set(),
  rows: new Map(),        // gid -> row element
  events: [],
  triggers: [],
  globalOptions: {},
  pendingOptions: {},   // key -> value saved to config.yaml but not live in aria2
  optInputs: new Map(),   // key -> {read, original, wrap}
  // gid -> {options: element, files: {index: checked}} — edits in an open
  // detail panel, kept across its two-second refresh.
  detailDrafts: new Map(),
  // The add dialog's number-and-unit fields.
  addUnits: null,
  rules: [],
  rulesEnabled: true,
  config: null,
  history: null,
  // gid -> true, for the bulk selection mode.
  selection: new Set(),
  selecting: false,
};

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/* ------------------------------------------------------------------ utils */
function fmtBytes(n, digits = 1) {
  n = Number(n) || 0;
  if (n < 1024) return `${n} B`;
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
  return `${n.toFixed(n < 10 ? digits : 0)} ${units[i]}`;
}
const fmtSpeed = (n) => (Number(n) > 0 ? `${fmtBytes(n)}/s` : '0 B/s');

function fmtEta(seconds) {
  if (seconds == null || seconds < 0) return '—';
  const s = Math.round(seconds);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}
const fmtTime = (ts) => new Date(ts * 1000).toLocaleTimeString();

function parseSize(value) {
  const text = String(value ?? '').trim();
  if (!text) return null;
  const m = text.match(/^([\d.]+)\s*([kmgt])?i?b?\/?s?$/i);
  if (!m) return Number(text) || null;
  const mult = { k: 1024, m: 1024 ** 2, g: 1024 ** 3, t: 1024 ** 4 }[(m[2] || '').toLowerCase()] || 1;
  return Math.round(parseFloat(m[1]) * mult);
}

/* config.yaml keeps sizes the way you wrote them and aria2 reports them in
   bytes, so `32M` and `33554432` are the same setting spelled two ways. A plain
   string compare called those a difference and marked untouched options as
   waiting for a restart. */
function sameOptionValue(live, saved) {
  const a = String(live ?? '').trim();
  const b = String(saved ?? '').trim();
  if (a === b) return true;
  const na = parseSize(a);
  const nb = parseSize(b);
  return na !== null && nb !== null && na === nb;
}

/* ------------------------------------------------------------------ units */
/* aria2 takes speeds and sizes in bytes and reports them in bytes, so every
   limit used to be a text box showing 12582912 and asking for arithmetic. These
   fields are a number and a unit instead. The value stays bytes underneath —
   what aria2 and config.yaml get — and shorthand like 12M typed into the box
   still works. */
const UNITS = {
  speed: [['B/s', 1], ['KiB/s', 1024], ['MiB/s', 1024 ** 2], ['GiB/s', 1024 ** 3]],
  size: [['B', 1], ['KiB', 1024], ['MiB', 1024 ** 2], ['GiB', 1024 ** 3]],
};
// The unit an empty or zero field starts on: what a limit is usually set in.
const DEFAULT_UNIT = 2;

// aria2 options that take a speed or a size, wherever they are shown.
const UNIT_OPTIONS = {
  'max-overall-download-limit': 'speed',
  'max-download-limit': 'speed',
  'max-overall-upload-limit': 'speed',
  'max-upload-limit': 'speed',
  'lowest-speed-limit': 'speed',
  'bt-request-peer-speed-limit': 'speed',
  'min-split-size': 'size',
  'disk-cache': 'size',
  'piece-length': 'size',
  'max-mmap-limit': 'size',
  'no-file-allocation-limit': 'size',
  'rpc-max-request-size': 'size',
  'socket-recv-buffer-size': 'size',
};

// bytes -> [amount, unit index], in the largest unit the value reaches 1 in.
// A speed of 0 is aria2's "no limit", which reads better as an empty box saying
// so than as "0 MiB/s".
function splitUnits(bytes, kind) {
  if (bytes == null) return ['', DEFAULT_UNIT];
  if (bytes === 0) return [kind === 'speed' ? '' : '0', DEFAULT_UNIT];
  const units = UNITS[kind];
  let index = 0;
  while (index < units.length - 1 && bytes >= units[index + 1][1]) index += 1;
  return [String(+(bytes / units[index][1]).toFixed(2)), index];
}

/* One number-and-unit control. read() gives bytes as a string ('' when empty).
   Changing the unit reinterprets the number rather than converting it: typing
   12 and picking MiB/s means 12 MiB/s. An untouched field reads back exactly
   what it was given, so rounding for display never counts as an edit. */
function unitInput(kind, raw, onEdit, placeholder) {
  const initialBytes = parseSize(raw);
  const [amount, unit] = splitUnits(initialBytes, kind);
  const wrap = document.createElement('span');
  wrap.className = 'unit-input';
  const input = document.createElement('input');
  input.inputMode = 'decimal';
  input.value = amount;
  input.placeholder = placeholder || (kind === 'speed' ? 'no limit' : '0');
  const select = document.createElement('select');
  select.innerHTML = UNITS[kind].map(([label], i) => `<option value="${i}">${label}</option>`).join('');
  select.value = String(unit);
  select.setAttribute('aria-label', 'Unit');
  wrap.append(input, select);

  const read = () => {
    const text = input.value.trim();
    if (text === amount && Number(select.value) === unit) return raw == null ? '' : String(raw);
    // Clearing a speed that was set means "no limit", not "leave it unset".
    if (!text) return kind === 'speed' && raw != null ? '0' : '';
    // Shorthand typed into the box carries its own unit.
    if (/[a-z]/i.test(text)) {
      const bytes = parseSize(text);
      return bytes == null ? text : String(bytes);
    }
    const number = Number(text);
    // Left as typed, so the manager's validation says what is wrong with it.
    if (!Number.isFinite(number) || number < 0) return text;
    return String(Math.round(number * UNITS[kind][Number(select.value)][1]));
  };
  const changed = () => { if (onEdit) onEdit(); };
  input.addEventListener('input', changed);
  select.addEventListener('change', changed);
  input.addEventListener('change', () => {
    if (!/[a-z]/i.test(input.value)) return;
    const bytes = parseSize(input.value);
    if (bytes == null) return;
    const [a, u] = splitUnits(bytes, kind);
    input.value = a;
    select.value = String(u);
    changed();
  });
  return { el: wrap, read };
}

function toast(message, kind = '') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = message;
  $('#toasts').append(el);
  setTimeout(() => el.remove(), kind === 'error' ? 7000 : 3200);
}

/* Requests go through lib/link.js: native messaging to the manager's socket. */
async function api(path, { method = 'GET', body } = {}) {
  const reply = await ManagerLink.call(method, path, body);
  if (reply.status < 200 || reply.status >= 300) throw new Error(ManagerLink.errorText(reply));
  return reply.body;
}

async function act(path, opts, okMessage) {
  try {
    const out = await api(path, opts);
    if (okMessage) toast(okMessage, 'ok');
    return out;
  } catch (err) {
    toast(err.message, 'error');
    throw err;
  }
}

/* ------------------------------------------------------------ live stream */
function connect() {
  ManagerLink.subscribe({
    onFrame(kind, data) {
      if (kind === 'state') applyState(data);
      else if (kind === 'event') pushEvents([data]);
      else if (kind === 'backlog') pushEvents(data, true);
    },
    // The stream reconnects on its own; this only has to say so.
    onError(reason) {
      setPill('disconnected', 'pill-err', reason);
    },
  });
}

function setPill(text, cls, title = '') {
  const pill = $('#aria2-pill');
  pill.textContent = text;
  pill.className = `pill ${cls}`;
  pill.title = title;
}

function pushEvents(events, replace = false) {
  if (!events || !events.length) return;
  S.events = replace ? events.slice() : events.concat(S.events);
  S.events.length = Math.min(S.events.length, 400);
  renderLog();
}

/* --------------------------------------------------------------- topbar */
function applyState(state) {
  S.state = state;
  const aria2 = state.aria2 || {};
  if (aria2.running) {
    setPill(`aria2c ${aria2.version || ''} · pid ${aria2.pid ?? 'ext'}`.trim(), 'pill-ok',
      `${aria2.rpc_url} · up ${fmtEta(aria2.uptime)}`);
  } else {
    setPill('aria2c not running', 'pill-err',
      aria2.last_error || 'no aria2c reachable — see the Log tab');
  }

  const g = state.global || {};
  $('#stat-down').textContent = fmtSpeed(g.downloadSpeed);
  $('#stat-up').textContent = fmtSpeed(g.uploadSpeed);
  const counts = state.counts || {};
  const queued = (counts.waiting ?? 0) + (counts.paused ?? 0);
  setStat('#stat-active', counts.active ?? 0);
  setStat('#stat-waiting', queued);
  setStat('#stat-complete', counts.complete ?? 0);
  setStat('#stat-error', counts.error ?? 0);

  // Every chip carries its own count — "All" and "Complete" included, which is
  // the pair that used to leave you guessing whether the filter was empty or
  // the list was.
  setCount('all', counts.total ?? (state.downloads || []).length);
  setCount('active', counts.active ?? 0);
  setCount('waiting', counts.waiting ?? 0);
  setCount('paused', counts.paused ?? 0);
  setCount('complete', counts.complete ?? 0);
  setCount('error', counts.error ?? 0);

  const rules = state.rules || {};
  $('#rules-master').checked = !!rules.enabled;
  S.rulesEnabled = !!rules.enabled;

  renderDownloads();
  renderProcInfo();
}

function setStat(sel, value) {
  const node = $(sel);
  if (!node) return;
  node.textContent = value;
  node.parentElement.classList.toggle('is-zero', !value);
}

function setCount(filter, value) {
  const node = $(`#count-${filter}`);
  if (node) node.textContent = value ? String(value) : '';
}

/* -------------------------------------------------------------- icons */
/* Inline SVG rather than emoji or glyphs: emoji render as someone else's
 * artwork at someone else's colour and size, and vary by platform. These
 * inherit currentColor and the button's font-size like any other icon set,
 * with nothing to download. Paths are 24x24. */
const ICONS = {
  pause: 'M6 19h4V5H6v14zm8-14v14h4V5h-4z',
  play: 'M8 5v14l11-7z',
  trash: 'M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z',
  close: 'M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z',
  retry: 'M17.65 6.35A7.96 7.96 0 0 0 12 4a8 8 0 1 0 7.73 10h-2.08A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z',
  top: 'M8 11h3v10h2V11h3l-4-4-4 4zM4 3v2h16V3H4z',
  up: 'M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z',
  down: 'M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z',
  broom: 'M5 13h14v-2H5v2zm-2 4h14v-2H3v2zM7 7v2h14V7H7z',
  select: 'M22 7l-1.41-1.41-6.34 6.34 1.41 1.41L22 7zM3 5v2h11V5H3zm0 6v2h8v-2H3zm0 6v2h8v-2H3z',
  open: 'M19 19H5V5h7V3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14c1.1 0 2-.9 2-2v-7h-2v7zM14 3v2h3.59l-9.83 9.83 1.41 1.41L19 6.41V10h2V3h-7z',
  chevron: 'M10 6 8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z',
  check: 'M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z',
};

function icon(name) {
  return `<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="${ICONS[name]}"/></svg>`;
}

/* ----------------------------------------------------------- downloads */
const STATUS_TAG = {
  active: 'tag-active', complete: 'tag-complete', error: 'tag-error',
  paused: 'tag-paused', waiting: '', removed: '',
};

function visibleDownloads() {
  const all = (S.state?.downloads || []).slice();
  // 'paused' sits with the running downloads rather than below the queue: a
  // pause is a halted in-progress item, and a rule's brief pause+resume would
  // otherwise make the row dive to the bottom of the list and jump back.
  const rank = { active: 0, paused: 0, waiting: 1, error: 2, complete: 3, removed: 4 };
  const acting = new Set(
    Object.entries(S.state?.rules?.downloads || {})
      .filter(([, rules]) => Object.values(rules).some((r) => r.acting))
      .map(([gid]) => gid)
  );
  const rankOf = (d) => (acting.has(d.gid) ? 0 : (rank[d.status] ?? 9));
  all.sort((a, b) => {
    const d = rankOf(a) - rankOf(b);
    if (d) return d;
    return (a.queuePosition ?? 0) - (b.queuePosition ?? 0);
  });
  const needle = S.search.toLowerCase();
  return all.filter((d) => {
    if (S.filter !== 'all' && d.status !== S.filter) return false;
    if (needle && !d.name.toLowerCase().includes(needle)) return false;
    return true;
  });
}

function renderDownloads() {
  if (S.filter === 'history') return;  // history is rendered from its own fetch
  const list = visibleDownloads();
  const container = $('#downloads');
  $('#empty').hidden = list.length > 0;

  const seen = new Set();
  list.forEach((dl, index) => {
    seen.add(dl.gid);
    let row = S.rows.get(dl.gid);
    if (!row) {
      row = buildRow(dl.gid);
      S.rows.set(dl.gid, row);
    }
    updateRow(row, dl);
    if (container.children[index] !== row) {
      container.insertBefore(row, container.children[index] || null);
    }
  });
  for (const [gid, row] of S.rows) {
    if (!seen.has(gid)) { row.remove(); S.rows.delete(gid); S.expanded.delete(gid); }
  }
}

function buildRow(gid) {
  const row = $('#row-template').content.firstElementChild.cloneNode(true);
  row.dataset.gid = gid;
  row._refs = {
    name: $('.dl-name', row),
    badges: $('.dl-badges', row),
    fill: $('.bar-fill', row),
    meta: $('.dl-meta', row),
    actions: $('.dl-actions', row),
    detail: $('.dl-detail', row),
    confirm: $('.dl-confirm', row),
    chev: $('.chev', row),
    pick: $('.dl-pick', row),
  };
  row._refs.pick.addEventListener('change', () => {
    if (row._refs.pick.checked) S.selection.add(gid);
    else S.selection.delete(gid);
    renderBulkBar();
    row.classList.toggle('is-selected', row._refs.pick.checked);
  });
  row._refs.chev.innerHTML = icon('chevron');
  row._refs.chev.addEventListener('click', () => toggleDetail(gid));
  row._refs.name.addEventListener('click', () => toggleDetail(gid));
  row._actionKey = '';
  return row;
}

function updateRow(row, dl) {
  const r = row._refs;
  row.className = `dl is-${dl.status}`;
  if (r.name.textContent !== dl.name) {
    r.name.textContent = dl.name;
    r.name.title = dl.path || dl.firstUri || dl.name;
  }

  const tags = [`<span class="tag ${STATUS_TAG[dl.status] || ''}">${dl.status}</span>`];
  // Explicit false only: undefined means the manager had no reason to look.
  if (dl.fileExists === false) tags.push('<span class="tag tag-missing">file missing</span>');
  if (dl.isTorrent) tags.push('<span class="tag">torrent</span>');
  if (dl.seeder) tags.push('<span class="tag tag-complete">seeding</span>');
  const ruleState = S.state?.rules?.downloads?.[dl.gid] || {};
  for (const [name, info] of Object.entries(ruleState)) {
    if (info.acting) tags.push(`<span class="tag tag-rule">${name}: acting</span>`);
    else if (info.triggers) tags.push(`<span class="tag tag-rule">${name} ×${info.triggers}</span>`);
  }
  const tagHtml = tags.join('');
  if (r.badges._html !== tagHtml) { r.badges.innerHTML = tagHtml; r.badges._html = tagHtml; }

  r.fill.style.width = `${dl.progress}%`;
  // Drives the wash across the card — see the note at the top of style.css.
  row.style.setProperty('--p', `${dl.progress}%`);
  r.pick.hidden = !S.selecting;
  r.pick.checked = S.selection.has(dl.gid);
  row.classList.toggle('is-selected', S.selecting && r.pick.checked);

  const bits = [
    `<span class="primary">${fmtBytes(dl.completed)} / ${dl.total ? fmtBytes(dl.total) : '?'}`
    + ` · ${dl.progress.toFixed(1)}%</span>`,
  ];
  if (dl.status === 'active') {
    // aria2's figure is a moving average; the measured one is bytes actually
    // written since the last tick. Show both when they disagree materially,
    // because that gap is what makes a stall look like it is still running.
    const measured = dl.measuredSpeed;
    const disagrees = measured != null
      && Math.abs(measured - dl.downloadSpeed) > Math.max(65536, dl.downloadSpeed * 0.35);
    bits.push(disagrees
      ? `↓ ${fmtSpeed(measured)} <span title="aria2 reports ${fmtSpeed(dl.downloadSpeed)} — its figure is a moving average and lags reality by a few seconds">(aria2 says ${fmtSpeed(dl.downloadSpeed)})</span>`
      : `↓ ${fmtSpeed(dl.downloadSpeed)}`);
    if (dl.isTorrent) bits.push(`↑ ${fmtSpeed(dl.uploadSpeed)}`);
    bits.push(`ETA ${fmtEta(dl.eta)}`);
    bits.push(`${dl.connections} conn`);
    if (dl.isTorrent) bits.push(`${dl.numSeeders} seeders`);
  }
  if (dl.status === 'waiting' && dl.queuePosition != null) bits.push(`queue #${dl.queuePosition + 1}`);
  if (dl.fileExists === false && dl.path) {
    bits.push(`<span class="err">file is no longer at ${escapeHtml(dl.path)}</span>`);
  }
  if (dl.errorMessage) bits.push(`<span class="err">${escapeHtml(dl.errorMessage)}</span>`);
  for (const [name, info] of Object.entries(ruleState)) {
    if (info.elapsed > 0 && info.threshold) {
      bits.push(`<span class="rulehint">${name} ${info.elapsed.toFixed(1)}/${info.threshold}s</span>`);
    }
  }
  const metaHtml = bits.map((b) => `<span>${b}</span>`).join('');
  if (r.meta._html !== metaHtml) { r.meta.innerHTML = metaHtml; r.meta._html = metaHtml; }

  // Rebuild the action buttons only when the applicable set changes.
  if (row._actionKey !== dl.status) {
    row._actionKey = dl.status;
    r.actions.innerHTML = '';
    for (const btn of actionsFor(dl)) r.actions.append(btn);
  }
}

async function removeDownload(gid, deleteFiles, okMessage) {
  const query = `?force=true&purge=true${deleteFiles ? '&delete_files=true' : ''}`;
  await act(`/api/download/${gid}${query}`, { method: 'DELETE' }, okMessage);
}

/* A finished download is the only case worth a question: its file is the point,
 * so removing the row and deleting the file are two different intentions. */
function askRemove(dl) {
  const row = S.rows.get(dl.gid);
  if (!row) return;
  const host = $('.dl-confirm', row);
  const gone = dl.fileExists === false;
  host.innerHTML = `<span class="question">${gone
    ? 'The file is already gone — remove the row?'
    : 'Remove this download — and the file?'}</span>`;
  const cancel = mkBtn2('Cancel', 'btn btn-small', () => { host.hidden = true; });
  const keep = mkBtn2('Keep file', 'btn btn-small',
    () => { host.hidden = true; removeDownload(dl.gid, false, 'Removed, file kept'); });
  const del = mkBtn2('Delete file', 'btn btn-small btn-danger',
    () => { host.hidden = true; removeDownload(dl.gid, true, 'Removed and deleted the file'); });
  del.disabled = gone;
  host.append(cancel, keep, del);
  host.hidden = false;
}

function mkBtn2(label, cls, handler) {
  const btn = document.createElement('button');
  btn.className = cls;
  btn.textContent = label;
  btn.addEventListener('click', handler);
  return btn;
}

function mkBtn(iconName, title, handler, cls = 'btn btn-icon') {
  const btn = document.createElement('button');
  btn.className = cls;
  btn.innerHTML = icon(iconName);
  btn.title = title;
  btn.setAttribute('aria-label', title);
  btn.addEventListener('click', handler);
  return btn;
}

function actionsFor(dl) {
  const gid = dl.gid;
  const out = [];
  if (dl.status === 'active' || dl.status === 'waiting') {
    out.push(mkBtn('pause', 'Pause', () => act(`/api/download/${gid}/pause`, { method: 'POST' })));
  }
  if (dl.status === 'paused') {
    out.push(mkBtn('play', 'Resume', () => act(`/api/download/${gid}/resume`, { method: 'POST' })));
  }
  if (dl.status === 'waiting' || dl.status === 'paused') {
    out.push(mkBtn('top', 'Move to top of queue',
      () => act(`/api/download/${gid}/position`, { method: 'POST', body: { pos: 0, how: 'POS_SET' } })));
    out.push(mkBtn('up', 'Move up',
      () => act(`/api/download/${gid}/position`, { method: 'POST', body: { pos: -1, how: 'POS_CUR' } })));
    out.push(mkBtn('down', 'Move down',
      () => act(`/api/download/${gid}/position`, { method: 'POST', body: { pos: 1, how: 'POS_CUR' } })));
  }
  if (dl.status === 'complete' && dl.path && dl.fileExists !== false) {
    out.push(mkBtn('open', 'Open the file', () => window.open(`file://${dl.path}`, '_blank')));
  }
  if (dl.status === 'error' || dl.status === 'complete' || dl.status === 'removed') {
    out.push(mkBtn('retry', 'Retry (re-add with the same URLs and options)',
      () => act(`/api/download/${gid}/retry`, { method: 'POST' }, 'Re-added')));
  }
  // A download still in flight is being cancelled — that is what a cross means.
  // One that has already stopped is being thrown away, which is the bin. And a
  // half-written part file is never worth keeping, so cancelling takes it with
  // it; only a finished download raises a question worth asking.
  const live = dl.status === 'active' || dl.status === 'waiting' || dl.status === 'paused';
  out.push(mkBtn(live ? 'close' : 'trash',
    live ? 'Cancel and remove' : 'Remove…',
    () => (live
      ? removeDownload(gid, true, 'Cancelled and cleaned up')
      : askRemove(dl)),
    'btn btn-icon btn-danger'));
  return out;
}

/* aria2's vocabulary is lower case in the protocol and in config.yaml; it is
   Capitalised wherever a person reads it, which is what the plugin does too. */
const capitalise = (text) => {
  const s = String(text ?? '');
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
};

const escapeHtml = (text) => String(text ?? '').replace(/[&<>"']/g,
  (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));

/* ------------------------------------------------------------- detail */
function toggleDetail(gid) {
  const row = S.rows.get(gid);
  if (!row) return;
  const open = S.expanded.has(gid);
  if (open) {
    S.expanded.delete(gid);
    S.detailDrafts.delete(gid);
    row._refs.detail.hidden = true;
    row._refs.chev.classList.remove('open');
  } else {
    S.expanded.add(gid);
    row._refs.detail.hidden = false;
    row._refs.chev.classList.add('open');
    row._refs.detail.innerHTML = '<p class="hint">Loading…</p>';
    refreshDetail(gid);
  }
}

async function refreshDetail(gid) {
  const row = S.rows.get(gid);
  if (!row || !S.expanded.has(gid)) return;
  let data;
  try {
    data = await api(`/api/download/${gid}`);
  } catch (err) {
    row._refs.detail.innerHTML = `<p class="hint" style="color:var(--err)">${escapeHtml(err.message)}</p>`;
    return;
  }
  renderDetail(row._refs.detail, gid, data);
}

function renderDetail(host, gid, data) {
  if (!S.detailDrafts.has(gid)) S.detailDrafts.set(gid, {});
  const draft = S.detailDrafts.get(gid);
  const st = data.status || {};
  const opts = data.options || {};
  const files = data.files || [];
  const active = (data.servers || []).flatMap((s) => (s.servers || []).map((x) => ({ index: s.index, ...x })));

  const pieces = data.pieceMap || [];
  const pieceHtml = pieces.length
    ? `<h3>Parts (${st.numPieces || 0} pieces × ${fmtBytes(st.pieceLength || 0)})</h3>
       <div class="piecemap">${pieces.map((p) =>
        `<i style="background:${p >= 100 ? 'var(--accent)' : p > 0 ? '#2d4f86' : 'var(--bg3)'}"></i>`).join('')}</div>`
    : '';

  host.innerHTML = `
    ${pieceHtml}
    <div class="detail-cols">
      <div>
        <h3>Info</h3>
        <div class="kv">
          <div><label>GID</label><code>${gid}</code></div>
          <div><label>Status</label><span class="tag ${STATUS_TAG[st.status] || ''}">${escapeHtml(st.status || '?')}</span></div>
          <div><label>Directory</label><code>${escapeHtml(st.dir || '')}</code></div>
          <div><label>Path</label><code>${escapeHtml(files[0]?.path || '')}</code></div>
          <div><label>Size</label><span>${fmtBytes(st.completedLength)} / ${fmtBytes(st.totalLength)}</span></div>
          <div><label>Connections</label><span>${st.connections || 0}</span></div>
          ${st.infoHash ? `<div><label>Info hash</label><code>${st.infoHash}</code></div>` : ''}
          ${st.errorMessage ? `<div><label>Error</label><span style="color:var(--err)">${escapeHtml(st.errorMessage)} (${st.errorCode})</span></div>` : ''}
        </div>
        <h3>Per-download options</h3>
        <div data-role="dl-opts"></div>
      </div>
      <div>
        <h3>Files ${files.length > 1 ? `(${files.length})` : ''}</h3>
        <div class="filelist">
          ${files.map((f) => `
            <div class="filerow">
              ${files.length > 1 ? `<input type="checkbox" data-file="${f.index}" ${(draft.files?.[f.index] ?? f.selected === 'true') ? 'checked' : ''}>` : ''}
              <span class="fname" title="${escapeHtml(f.path)}">${escapeHtml(f.path.split('/').pop() || f.path)}</span>
              <span class="fsize">${fmtBytes(f.completedLength)}/${fmtBytes(f.length)}</span>
            </div>`).join('') || '<p class="hint">No file info yet.</p>'}
        </div>
        ${files.length > 1 ? '<button class="btn btn-small" data-role="save-files" style="margin-top:8px">Apply file selection</button>' : ''}
        <h3>Live connections ${active.length ? `(${active.length})` : ''}</h3>
        <div class="serverlist">
          ${active.map((s) => `
            <div class="filerow">
              <span class="fname" title="${escapeHtml(s.currentUri || s.uri)}">${escapeHtml((s.currentUri || s.uri || '').slice(0, 70))}</span>
              <span class="fsize">${fmtSpeed(s.downloadSpeed)}</span>
            </div>`).join('') || '<p class="hint">No active connections.</p>'}
        </div>
        ${(data.uris || []).length ? `<h3>URLs</h3><div class="filelist">${
          data.uris.map((u) => `<div class="filerow"><span class="fname" title="${escapeHtml(u.uri)}">${escapeHtml(u.uri)}</span><span class="fsize">${u.status}</span></div>`).join('')
        }</div>` : ''}
        ${(data.peers || []).length ? `<h3>Peers (${data.peers.length})</h3><div class="filelist">${
          data.peers.slice(0, 25).map((p) => `<div class="filerow"><span class="fname">${escapeHtml(p.ip)}:${p.port}</span><span class="fsize">↓${fmtSpeed(p.downloadSpeed)} ↑${fmtSpeed(p.uploadSpeed)}</span></div>`).join('')
        }</div>` : ''}
      </div>
    </div>`;

  // Rebuilt every two seconds for the live figures, but what the user is in the
  // middle of editing must survive that: the options block is built once per
  // expansion and moved into each new render, and file ticks are remembered.
  const optsHost = $('[data-role="dl-opts"]', host);
  if (!draft.options) draft.options = buildDownloadOptions(gid, opts);
  optsHost.replaceWith(draft.options);
  for (const box of $$('[data-file]', host)) {
    box.addEventListener('change', () => {
      draft.files = draft.files || {};
      draft.files[box.dataset.file] = box.checked;
    });
  }
  $('[data-role="save-files"]', host)?.addEventListener('click', async () => {
    const indices = $$('[data-file]', host).filter((c) => c.checked).map((c) => Number(c.dataset.file));
    if (!indices.length) { toast('Select at least one file', 'error'); return; }
    await act(`/api/download/${gid}/select`, { method: 'POST', body: { indices } }, 'Selection applied');
    draft.files = null;
  });
}

function buildDownloadOptions(gid, opts) {
  const block = document.createElement('div');
  const fields = [];
  const row = (label, control) => {
    const line = document.createElement('div');
    line.className = 'optrow';
    const lab = document.createElement('label');
    lab.textContent = label;
    line.append(lab, control);
    block.append(line);
  };
  for (const [key, label] of [['split', 'Split (parts)'], ['max-connection-per-server', 'Connections per server']]) {
    const input = document.createElement('input');
    input.type = 'number';
    input.min = '1';
    input.value = opts[key] || '';
    fields.push([key, () => input.value.trim(), opts[key] || '']);
    row(label, input);
  }
  for (const [key, label] of [['max-download-limit', 'Download limit'], ['max-upload-limit', 'Upload limit']]) {
    const unitField = unitInput('speed', opts[key] ?? null);
    fields.push([key, unitField.read, opts[key] || '']);
    row(label, unitField.el);
  }
  const apply = document.createElement('button');
  apply.className = 'btn btn-small';
  apply.textContent = 'Apply to this download';
  apply.addEventListener('click', async () => {
    const options = {};
    for (const [key, read, original] of fields) {
      const value = read();
      if (value && !sameOptionValue(value, original)) options[key] = value;
    }
    if (!Object.keys(options).length) { toast('Nothing changed'); return; }
    await act(`/api/download/${gid}/options`, { method: 'POST', body: { options } }, 'Options applied');
    // Start from the applied values next time the panel renders.
    S.detailDrafts.delete(gid);
  });
  const line = document.createElement('div');
  line.className = 'optrow';
  line.append(apply);
  block.append(line);
  return block;
}

setInterval(() => { for (const gid of S.expanded) refreshDetail(gid); }, 2000);

/* ------------------------------------------------------------ add dialog */
function openAdd() {
  $('#add-dialog').showModal();
  $('#add-uris').focus();
}

function collectAddOptions() {
  const options = {};
  const put = (key, value) => { if (value != null && String(value).trim()) options[key] = String(value).trim(); };
  put('dir', $('#add-dir').value);
  put('out', $('#add-out').value);
  put('max-connection-per-server', $('#add-conn').value);
  put('split', $('#add-split').value);
  put('min-split-size', S.addUnits.minSplit.read());
  put('max-download-limit', S.addUnits.limit.read());
  put('referer', $('#add-referer').value);
  put('user-agent', $('#add-ua').value);
  put('all-proxy', $('#add-proxy').value);
  put('checksum', $('#add-checksum').value);

  const headers = $('#add-headers').value.split('\n').map((l) => l.trim()).filter(Boolean);
  const cookie = $('#add-cookie').value.trim();
  if (cookie) headers.push(`Cookie: ${cookie}`);
  if (headers.length) options.header = headers;
  return options;
}

async function submitAdd() {
  const file = $('#add-file').files[0];
  const uris = $('#add-uris').value.split('\n').map((l) => l.trim()).filter(Boolean);
  if (!file && !uris.length) { toast('Give a URL or pick a torrent file', 'error'); return; }

  const options = collectAddOptions();
  const positionRaw = $('#add-position').value.trim();
  const position = positionRaw === '' ? null : Number(positionRaw);
  const paused = $('#add-paused').checked;

  try {
    if (file) {
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).split(',')[1]);
        reader.onerror = () => reject(new Error('could not read file'));
        reader.readAsDataURL(file);
      });
      const kind = /\.meta(4|link)$/i.test(file.name) ? 'metalink' : 'torrent';
      await api('/api/downloads/file', {
        method: 'POST',
        body: { data, kind, filename: file.name, uris, options, position, paused },
      });
    } else {
      await api('/api/downloads', {
        method: 'POST',
        body: { uris, options, position, paused, mirrors: $('#add-mirrors').checked },
      });
    }
    toast('Queued', 'ok');
    $('#add-dialog').close();
    $('#add-uris').value = '';
    $('#add-file').value = '';
  } catch (err) {
    toast(err.message, 'error');
  }
}

/* -------------------------------------------------------------- settings */
const OPTION_GROUPS = [
  ['Queue & parallelism', [
    ["max-concurrent-downloads", "Max concurrent downloads", "number"],
    ["max-connection-per-server", "Connections per server (max 16)", "number"],
    ["split", "Split \u2014 parts per download", "number"],
    ["min-split-size", "Minimum part size", "text"],
    ["optimize-concurrent-downloads", "Auto-tune concurrency", "bool"],
  ]],
  ['Speed limits', [
    ["max-overall-download-limit", "Overall download limit", "text"],
    ["max-download-limit", "Per-download limit", "text"],
    ["max-overall-upload-limit", "Overall upload limit", "text"],
    ["max-upload-limit", "Per-download upload limit", "text"],
    ["lowest-speed-limit", "Abort below this speed", "text"],
  ]],
  ['Retries & timeouts', [
    ["max-tries", "Max tries (0 = unlimited)", "number"],
    ["retry-wait", "Retry wait (s)", "number"],
    ["timeout", "Timeout (s)", "number"],
    ["connect-timeout", "Connect timeout (s)", "number"],
    ["max-file-not-found", "Max 404s before giving up", "number"],
  ]],
  ['Disk & files', [
    ["dir", "Download directory", "text"],
    ["file-allocation", "File allocation", "select:none,prealloc,trunc,falloc"],
    ["disk-cache", "Disk cache", "text"],
    ["continue", "Resume partial files", "bool"],
    ["allow-overwrite", "Allow overwrite", "bool"],
    ["auto-file-renaming", "Auto-rename duplicates", "bool"],
    ["remote-time", "Use server timestamps", "bool"],
  ]],
  ['HTTP', [
    ["user-agent", "User-Agent", "text"],
    ["referer", "Referer", "text"],
    ["http-accept-gzip", "Accept gzip", "bool"],
    ["all-proxy", "Proxy (all protocols)", "text"],
    ["check-certificate", "Verify TLS certificates", "bool"],
  ]],
  ['BitTorrent', [
    ["follow-torrent", "Auto-start downloaded torrents", "bool"],
    ["bt-max-peers", "Max peers", "number"],
    ["seed-ratio", "Seed ratio", "text"],
    ["seed-time", "Seed time (min)", "text"],
    ["enable-dht", "Enable DHT", "bool"],
    ["bt-max-open-files", "Max open files", "number"],
  ]],
];

/* A <label>, not a <span>. The checkbox inside is visually hidden (0x0,
   opacity 0) so the track can be styled, which means the only thing that can
   deliver a click to it is a label wrapping it — as a span, every switch in the
   options grid was inert: the track took the click and nothing received it. */
function boolSwitch(checked, unset) {
  const box = document.createElement('label');
  box.className = 'switch' + (unset ? ' unset' : '');
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.checked = checked;
  const track = document.createElement('span');
  track.className = 'track';
  const knob = document.createElement('span');
  knob.className = 'knob';
  track.append(knob);
  box.append(input, track);
  return { box, input };
}

/* aria2's own option names carry their topic as a prefix, which is the only
   structure on offer for the ~120 options it reports beyond the curated set.
   Grouping on it turns one alphabetical wall into the same cards the curated
   settings use — still unexplained, but at least navigable. Order matters: the
   first rule that matches wins, so the specific ones come before the general. */
const ADVANCED_GROUPS = [
  ['BitTorrent', /^(bt-|dht|peer-|seed-|follow-torrent|listen-port|enable-peer-exchange|max-open-files)/],
  ['Metalink', /^(metalink|follow-metalink)/],
  ['HTTP', /^(http|header|user-agent|referer|content-disposition|use-head|enable-http)/],
  ['FTP', /^ftp/],
  ['Proxy', /proxy/],
  ['RPC', /^rpc/],
  ['Logging', /^(log|console-|quiet|summary-interval|show-|truncate-)/],
  ['Disk & files', /^(dir|disk-|file-|save-|no-file-|allow-|auto-file|conf-path|netrc|ca-cert|check-|piece-|hash-|realtime-|remove-control|force-save|auto-save)/],
  ['Transfer', /^(max-|min-|split|timeout|connect-timeout|retry|lowest-|stream-|uri-selector|server-stat|async-dns|conditional-get|always-resume|continue|deferred|reuse-uri|remote-time|parameterized|stop|pause|daemon|human-readable|no-conf|no-netrc|help)/],
];

function groupAdvanced(keys) {
  const buckets = new Map(ADVANCED_GROUPS.map(([title]) => [title, []]));
  buckets.set('Other', []);
  for (const key of keys) {
    const hit = ADVANCED_GROUPS.find(([, re]) => re.test(key));
    buckets.get(hit ? hit[0] : 'Other').push(key);
  }
  return [...buckets].filter(([, list]) => list.length);
}

function optionField(key, label, kind, value, desc) {
  const wrap = document.createElement('div');
  wrap.className = 'optfield';
  const pending = S.pendingOptions?.[key];
  if (pending !== undefined) value = pending;
  const lab = document.createElement('label');
  lab.innerHTML = `${escapeHtml(label)}`
    + (pending !== undefined
      ? ' <span class="tag tag-pending">restart to apply</span>' : '')
    + (desc ? `<em>${escapeHtml(desc)}</em>` : '')
    + (label === key ? '' : `<small>${key}</small>`);
  const original = value ?? '';
  let read;
  let control;

  if (kind === 'bool') {
    // aria2 does not report every option. An unset one stays visibly undecided
    // rather than being written out as an explicit false the moment it renders.
    let unset = value == null || value === '';
    const { box, input } = boolSwitch(value === 'true', unset);
    const note = document.createElement('span');
    note.className = 'unset-note';
    note.textContent = unset ? 'not set' : '';
    input.addEventListener('change', () => {
      unset = false;
      box.classList.remove('unset');
      note.textContent = '';
      wrap.classList.toggle('dirty', read() !== original);
    });
    read = () => (unset ? '' : (input.checked ? 'true' : 'false'));
    control = document.createElement('span');
    control.className = 'boolcell';
    control.append(note, box);
  } else if (kind && kind.startsWith('select:')) {
    const input = document.createElement('select');
    const choices = kind.slice(7).split(',');
    const unset = value == null || value === '' || !choices.includes(value);
    input.innerHTML = (unset ? '<option value="">(unset)</option>' : '')
      + choices.map((v) => `<option value="${v}">${v}</option>`).join('');
    input.value = unset ? '' : value;
    input.addEventListener('change', () => wrap.classList.toggle('dirty', input.value !== original));
    read = () => input.value;
    control = input;
  } else if (UNIT_OPTIONS[key]) {
    const unitField = unitInput(UNIT_OPTIONS[key], original === '' ? null : original,
      () => wrap.classList.toggle('dirty', !sameOptionValue(unitField.read(), original)));
    read = unitField.read;
    control = unitField.el;
  } else {
    const input = document.createElement('input');
    if (kind === 'number') input.type = 'number';
    input.value = original;
    const mark = () => wrap.classList.toggle('dirty', input.value !== original);
    input.addEventListener('input', mark);
    input.addEventListener('change', mark);
    read = () => input.value;
    control = input;
  }

  S.optInputs.set(key, { read, original, wrap });
  wrap.append(lab, control);
  return wrap;
}

async function loadGlobalOptions() {
  try {
    S.globalOptions = await api('/api/global/options');
  } catch (err) {
    toast(`Could not read aria2 options: ${err.message}`, 'error');
    return;
  }
  /* aria2 refuses to change most of its options while it is running: the RPC
     answers OK and keeps the old value. Those edits are still written to
     config.yaml, so the option is set — it just is not live yet. Showing only
     aria2's live value made a saved edit look like it had been thrown away, so
     a key whose saved value differs from the running one is shown at its saved
     value and marked as waiting for a restart. */
  S.pendingOptions = {};
  // The settings tab can be opened before the startup config fetch lands.
  if (!S.config) { try { S.config = await api('/api/config'); } catch (err) { /* ignore */ } }
  const saved = (S.config?.aria2?.options) || {};
  for (const [key, value] of Object.entries(saved)) {
    if (key in S.globalOptions && !sameOptionValue(S.globalOptions[key], value)) {
      S.pendingOptions[key] = String(value);
    }
  }
  S.optInputs.clear();
  const groupsHost = $('#options-groups');
  groupsHost.innerHTML = '';
  const covered = new Set();
  for (const [title, opts] of OPTION_GROUPS) {
    const group = document.createElement('div');
    group.className = 'optgroup';
    group.innerHTML = `<h3>${title}</h3>`;
    const grid = document.createElement('div');
    grid.className = 'optgrid';
    for (const [key, label, kind, desc] of opts) {
      covered.add(key);
      grid.append(optionField(key, label, kind, S.globalOptions[key], desc));
    }
    group.append(grid);
    groupsHost.append(group);
  }
  const advanced = $('#options-advanced');
  advanced.innerHTML = '';
  const rest = Object.keys(S.globalOptions).sort().filter((k) => !covered.has(k));
  // The plugin's fold shows its count, so this one does too — a collapsed
  // section with no number on it reads as though the options are missing.
  const counter = $('#advanced-count');
  if (counter) counter.textContent = ` — ${rest.length}`;
  for (const [title, keys] of groupAdvanced(rest)) {
    const group = document.createElement('div');
    group.className = 'optgroup';
    group.innerHTML = `<h3>${title}</h3>`;
    const grid = document.createElement('div');
    grid.className = 'optgrid';
    for (const key of keys) {
      // aria2 reports booleans as the strings "true"/"false"; they get a switch
      // like every other boolean rather than a text box to type a word into.
      const raw = S.globalOptions[key];
      const kind = (raw === 'true' || raw === 'false') ? 'bool' : 'text';
      grid.append(optionField(key, key, kind, raw,
        (typeof OPTION_HELP === 'object' && OPTION_HELP[key]) || ''));
    }
    group.append(grid);
    advanced.append(group);
  }
  applyOptionFilter();
}

function applyOptionFilter() {
  const needle = $('#opt-search').value.trim().toLowerCase();
  for (const [key, { wrap }] of S.optInputs) {
    const label = wrap.querySelector('label')?.textContent.toLowerCase() || '';
    wrap.style.display = !needle || key.includes(needle) || label.includes(needle) ? '' : 'none';
  }
}

async function saveGlobalOptions() {
  const options = {};
  for (const [key, { read, original }] of S.optInputs) {
    const value = read();
    // By value: 32M and 33554432 are the same setting.
    if (!sameOptionValue(value, original)) options[key] = value;
  }
  if (!Object.keys(options).length) { toast('Nothing changed'); return; }
  try {
    const res = await api('/api/global/options', { method: 'POST', body: { options } });
    const live = Object.keys(res.applied || {}).length;
    const later = Object.keys(res.pending || {}).length;
    if (later) {
      toast(live
        ? `${live} applied · ${later} saved, needs an aria2c restart`
        : `${later} saved — aria2c will not change ${later === 1 ? 'it' : 'them'} while running, restart to apply`,
      'ok');
    } else {
      toast(`Applied ${live} option(s)`, 'ok');
    }
    // Re-read the saved config too, or a pending option loses its marker.
    try { S.config = await api('/api/config'); } catch (err) { /* keep the old copy */ }
    await loadGlobalOptions();
  } catch (err) {
    toast(err.message, 'error');
  }
}

function renderProcInfo() {
  const aria2 = S.state?.aria2 || {};
  $('#proc-info').innerHTML = Object.entries({
    Managed: aria2.managed ? 'yes (spawned by manager)' : 'no (external)',
    Running: aria2.running ? 'yes' : 'no',
    PID: aria2.pid ?? '—',
    Version: aria2.version || '—',
    'RPC URL': aria2.rpc_url || '—',
    Uptime: fmtEta(aria2.uptime),
    Restarts: aria2.restarts ?? 0,
    'Log file': aria2.log_file || '—',
    'Session file': aria2.session_file || '—',
    'Last error': aria2.last_error || 'none',
  }).map(([k, v]) => `<div><label>${k}</label><code>${escapeHtml(v)}</code></div>`).join('');
}

/* -------------------------------------------------------------- history */
async function loadHistory() {
  try {
    S.history = await api('/api/history?limit=300');
  } catch (err) {
    toast(err.message, 'error');
    return;
  }
  renderHistory();
}

function renderHistory() {
  const data = S.history;
  const host = $('#downloads');
  const bar = $('#history-bar');
  if (S.filter !== 'history') { bar.hidden = true; return; }
  bar.hidden = false;
  if (!data) return;

  const s = data.summary || {};
  $('#history-summary').textContent =
    `${s.count || 0} recorded (${s.completed || 0} completed, ${fmtBytes(s.bytes || 0)}) — kept in ${s.file || ''}`;

  const rows = data.entries || [];
  $('#empty').hidden = rows.length > 0;
  host.innerHTML = rows.map((e) => {
    const tag = e.status === 'complete' ? 'tag-complete'
      : e.status === 'error' ? 'tag-error' : '';
    return `<article class="job state-${e.status}">
      <div class="hist-row">
        <span class="job-name">${escapeHtml(e.name || e.key)}</span>
        <span class="tag ${tag}">${escapeHtml(e.status)}</span>
        <span class="spacer"></span>
        <span class="job-actions">
          ${e.url ? `<button class="btn btn-icon" data-hist="readd" data-key="${escapeHtml(e.key)}" title="Download this again" aria-label="Download this again">${icon('retry')}</button>` : ''}
          <button class="btn btn-icon btn-danger" data-hist="remove" data-key="${escapeHtml(e.key)}" title="Forget this entry" aria-label="Forget this entry">${icon('trash')}</button>
        </span>
      </div>
      <div class="job-meta">
        <span>${fmtBytes(e.completed)}${e.total && e.total !== e.completed ? ` / ${fmtBytes(e.total)}` : ''}</span>
        <span>${e.finished_at ? new Date(e.finished_at * 1000).toLocaleString() : ''}</span>
        ${e.path ? `<span title="${escapeHtml(e.path)}">${escapeHtml(e.dir || '')}</span>` : ''}
        ${e.error ? `<span style="color:var(--err)">${escapeHtml(e.error)}</span>` : ''}
      </div>
    </article>`;
  }).join('');

  for (const btn of $$('[data-hist]', host)) {
    btn.addEventListener('click', async () => {
      const key = btn.dataset.key;
      if (btn.dataset.hist === 'readd') {
        await act('/api/history/readd', { method: 'POST', body: { key } }, 'Queued again');
      } else {
        await act('/api/history/remove', { method: 'POST', body: { key } });
      }
      loadHistory();
    });
  }
}

/* ----------------------------------------------------------------- rules */
// aria2's own status vocabulary, in the order the filter bar shows it.
const KNOWN_STATUSES = ['active', 'waiting', 'paused', 'error', 'complete', 'removed'];

const RULE_FIELDS = [
  ['when.speed_below', 'Speed below', 'speed'],
  ['when.for_seconds', 'Hold for (s)', 'number'],
  ['when.min_age_seconds', 'Ignore first (s)', 'number'],
  ['cooldown_seconds', 'Cooldown (s)', 'number'],
  ['resume_after_seconds', 'Resume after (s)', 'number'],
  ['max_triggers', 'Max triggers (0 = ∞)', 'number'],
  ['when.min_progress', 'Only above progress %', 'number'],
  ['when.max_progress', 'Only below progress %', 'number'],
  ['when.connections_below', 'Connections below', 'number'],
  ['when.name_matches', 'Name matches (regex)', 'text'],
];

// value -> what the user reads. The values are the literal config keys, so they
// stay snake_case in config.yaml and the raw-JSON editor.
const ACTION_LABEL = {
  pause_resume: 'Pause + resume',
  force_pause_resume: 'Force pause + resume',
  restart: 'Restart (remove and re-add)',
  set_option: 'Change its options',
  stop: 'Pause and leave paused',
  log_only: 'Log only (do nothing)',
};
const ACTIONS = Object.keys(ACTION_LABEL);
const actionLabel = (value) => ACTION_LABEL[value] || String(value || '').replace(/_/g, ' ');

const getPath = (obj, path) => path.split('.').reduce((node, key) => (node == null ? node : node[key]), obj);
function setPath(obj, path, value) {
  const keys = path.split('.');
  const last = keys.pop();
  let node = obj;
  for (const key of keys) node = node[key] ??= {};
  if (value === '' || value == null) delete node[last];
  else node[last] = value;
}

async function loadRules() {
  try {
    const data = await api('/api/rules');
    S.rules = data.rules || [];
    S.rulesEnabled = !!data.enabled;
    if (data.speed_source) $('#rules-speed-source').value = data.speed_source;
    S.triggers = data.triggers || [];
    $('#rules-master').checked = S.rulesEnabled;
    renderRules();
  } catch (err) {
    toast(err.message, 'error');
  }
}

function renderRules() {
  const host = $('#rules-list');
  host.innerHTML = '';
  $('#rules-badge').textContent = S.rules.filter((r) => r.enabled !== false).length;

  S.rules.forEach((rule, index) => {
    const card = document.createElement('div');
    card.className = `rule${rule.enabled === false ? ' disabled' : ''}`;

    const head = document.createElement('div');
    head.className = 'rule-head';
    const { box: toggleBox, input: toggle } = boolSwitch(rule.enabled !== false, false);
    toggleBox.title = 'Enable this rule';
    toggle.addEventListener('change', () => { rule.enabled = toggle.checked; renderRules(); });

    const name = document.createElement('input');
    name.className = 'rname';
    name.value = rule.name || '';
    name.placeholder = 'rule-name';
    name.addEventListener('change', () => { rule.name = name.value.trim(); });

    const action = document.createElement('select');
    action.innerHTML = ACTIONS
      .map((a) => `<option value="${a}">${escapeHtml(actionLabel(a))}</option>`).join('');
    action.value = rule.action || 'pause_resume';
    action.addEventListener('change', () => { rule.action = action.value; renderRules(); });

    const del = mkBtn('trash', 'Delete rule', () => {
      S.rules.splice(index, 1);
      renderRules();
    }, 'btn btn-icon btn-danger');

    head.append(toggleBox, name, del);
    card.append(head);

    /* The action is the rule's main decision, so it gets a labelled field of
       its own rather than riding along unlabelled in the title row — which is
       where the plugin puts it, and it was the only control in the card with no
       label saying what it sets. */
    const actionField = document.createElement('label');
    actionField.className = 'field rule-action';
    const actionLab = document.createElement('span');
    actionLab.textContent = 'Action';
    actionField.append(actionLab, action);
    card.append(actionField);

    const grid = document.createElement('div');
    grid.className = 'rule-grid';
    for (const [path, label, kind] of RULE_FIELDS) {
      const field = document.createElement('label');
      field.className = 'field';
      const span = document.createElement('span');
      span.textContent = label;
      if (kind === 'speed') {
        const current = getPath(rule, path);
        const unitField = unitInput('speed', current ?? null, () => {
          const value = unitField.read();
          setPath(rule, path, value === '' || !Number.isFinite(Number(value)) ? value : Number(value));
        });
        field.append(span, unitField.el);
        grid.append(field);
        continue;
      }
      const input = document.createElement('input');
      if (kind === 'number') input.type = 'number';
      input.value = getPath(rule, path) ?? '';
      input.addEventListener('change', () => {
        let value = input.value.trim();
        if (value === '') { setPath(rule, path, ''); return; }
        if (kind === 'number') value = Number(value);
        setPath(rule, path, value);
      });
      field.append(span, input);
      grid.append(field);
    }
    card.append(grid);

    /* aria2's status vocabulary is a fixed, short list, so it is offered as
       chips you toggle — the same control the filter bar above the download
       list uses, and the same one the DankBar plugin's rule card uses. It was a
       text box you typed comma-separated words into, which asked you to know
       the vocabulary by heart and spell it correctly. Anything already saved in
       config.yaml is kept in the list even if it is not one of the known names,
       so a hand-edited rule never silently loses a value it cannot show. */
    const statuses = document.createElement('div');
    statuses.className = 'field';
    statuses.innerHTML = '<span>Applies to statuses</span>';
    const chosen = ((rule.when || {}).statuses || ['active']).slice();
    const names = KNOWN_STATUSES.concat(chosen.filter((s) => !KNOWN_STATUSES.includes(s)));
    const chipRow = document.createElement('div');
    chipRow.className = 'chiprow';
    for (const name of names) {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = `chip${chosen.includes(name) ? ' active' : ''}`;
      // Capitalised, and a check on the ones that are on: these are a
      // multi-select, so the chosen set has to be readable at a glance rather
      // than inferred from a background tint alone.
      chip.innerHTML = `<span class="check" aria-hidden="true">${icon('check')}</span>${escapeHtml(capitalise(name))}`;
      chip.addEventListener('click', () => {
        const at = chosen.indexOf(name);
        if (at >= 0) chosen.splice(at, 1); else chosen.push(name);
        // aria2 needs at least one status and the daemon falls back to active
        // anyway, so say so rather than saving nothing.
        const next = chosen.length ? chosen : ['active'];
        setPath(rule, 'when.statuses', next.slice());
        chip.classList.toggle('active', chosen.includes(name));
        if (!chosen.length) renderRules();
      });
      chipRow.append(chip);
    }
    statuses.append(chipRow);
    card.append(statuses);

    const descField = document.createElement('label');
    descField.className = 'field';
    const descLab = document.createElement('span');
    descLab.textContent = 'Description';
    const desc = document.createElement('input');
    desc.className = 'rule-desc';
    desc.placeholder = 'What this rule is for (optional)';
    desc.value = rule.description || '';
    desc.addEventListener('change', () => { rule.description = desc.value; });
    descField.append(descLab, desc);
    card.append(descField);

    if (rule.action === 'set_option') {
      const hint = document.createElement('p');
      hint.className = 'hint';
      hint.textContent = 'set_option needs an "options" mapping — edit it in the raw JSON below.';
      card.append(hint);
    }

    const details = document.createElement('details');
    details.className = 'rule-json';
    details.innerHTML = '<summary>Raw JSON (full control)</summary>';
    const area = document.createElement('textarea');
    area.rows = 10;
    area.value = JSON.stringify(rule, null, 2);
    area.addEventListener('change', () => {
      try {
        S.rules[index] = JSON.parse(area.value);
        renderRules();
      } catch (err) {
        toast(`Invalid JSON: ${err.message}`, 'error');
      }
    });
    details.append(area);
    card.append(details);

    host.append(card);
  });

  renderTriggers();
}

function renderTriggers() {
  $('#rule-triggers').innerHTML = S.triggers.length
    ? S.triggers.map((t) => `
        <div class="logline rule">
          <time>${fmtTime(t.ts)}</time><span class="lvl">rule</span>
          <span class="msg"><b>${escapeHtml(t.rule)}</b> · ${escapeHtml(actionLabel(t.action))} → ${escapeHtml(t.name)} @ ${fmtSpeed(t.speed)}${t.detail ? ` (${escapeHtml(t.detail)})` : ''}</span>
        </div>`).join('')
    : '<p class="hint">No rule has fired yet.</p>';
}

async function saveRules() {
  try {
    const data = await api('/api/rules', {
      method: 'POST',
      body: {
        rules: S.rules,
        enabled: $('#rules-master').checked,
        speed_source: $('#rules-speed-source').value,
      },
    });
    S.rules = data.rules;
    toast('Rules saved', 'ok');
    renderRules();
  } catch (err) {
    toast(err.message, 'error');
  }
}

function addRule() {
  S.rules.push({
    name: `rule-${S.rules.length + 1}`,
    enabled: true,
    description: '',
    when: { statuses: ['active'], speed_below: 51200, for_seconds: 3, min_age_seconds: 8 },
    action: 'pause_resume',
    resume_after_seconds: 1.5,
    cooldown_seconds: 25,
    max_triggers: 20,
  });
  renderRules();
}

/* ------------------------------------------------------------------- log */
function renderLog() {
  const host = $('#loglist');
  host.innerHTML = S.events.map((e) => `
    <div class="logline ${e.level}">
      <time>${fmtTime(e.ts)}</time><span class="lvl">${e.level}</span>
      <span class="msg">${escapeHtml(e.message)}</span>
    </div>`).join('') || '<p class="hint">Nothing logged yet.</p>';
  if (S.events.some((e) => e.level === 'rule')) {
    S.triggers = S.events.filter((e) => e.level === 'rule').map((e) => ({
      ts: e.ts, rule: e.rule || '?', action: e.action || '', name: e.message, speed: e.speed || 0, detail: '',
    }));
    if ($('#tab-rules').classList.contains('active')) renderTriggers();
  }
}

/* ------------------------------------------------------------- bulk mode */
function setSelecting(on) {
  S.selecting = on;
  if (!on) S.selection.clear();
  $('#btn-select').classList.toggle('btn-primary', on);
  $('#btn-select').textContent = on ? 'Done' : 'Select';
  $('#bulk-confirm').hidden = true;
  renderBulkBar();
  renderDownloads();
}

function selectedRows() {
  const known = new Map((S.state?.downloads || []).map((d) => [d.gid, d]));
  return [...S.selection].map((gid) => known.get(gid)).filter(Boolean);
}

function renderBulkBar() {
  const bar = $('#bulk-bar');
  bar.hidden = !S.selecting || S.filter === 'history';
  const n = S.selection.size;
  $('#bulk-count').textContent = n === 1 ? '1 selected' : `${n} selected`;
  for (const id of ['#bulk-pause', '#bulk-resume', '#bulk-remove']) $(id).disabled = !n;
  const visible = visibleDownloads();
  $('#bulk-all').textContent = n && n >= visible.length ? 'None' : 'All';
}

async function bulk(action, gids, deleteFiles) {
  if (!gids.length) return null;
  return act('/api/downloads/bulk', {
    method: 'POST',
    body: { action, gids, delete_files: !!deleteFiles, force: true },
  });
}

/* Unfinished downloads are cleaned up without asking — a part file is never
 * worth keeping. Only the finished ones in the selection raise the question. */
function askBulkRemove() {
  const rows = selectedRows();
  const finished = rows.filter((d) => d.status === 'complete');
  if (!finished.length) { runBulkRemove(false); return; }
  const rest = rows.length - finished.length;
  $('#bulk-question').textContent =
    `${finished.length} finished — keep the files?`
    + (rest ? `  (${rest} unfinished will be cleaned up)` : '');
  $('#bulk-confirm').hidden = false;
}

async function runBulkRemove(keepFinishedFiles) {
  const rows = selectedRows();
  const finished = rows.filter((d) => d.status === 'complete').map((d) => d.gid);
  const unfinished = rows.filter((d) => d.status !== 'complete').map((d) => d.gid);
  $('#bulk-confirm').hidden = true;
  let out = null;
  if (unfinished.length) out = await bulk('remove', unfinished, true);
  if (finished.length) out = await bulk('remove', finished, !keepFinishedFiles);
  if (out && out.message) toast(out.message, 'ok');
  S.selection.clear();
  renderBulkBar();
}

/* ------------------------------------------------------------------ wire */
function switchTab(name) {
  $$('.tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
  $$('.tabpane').forEach((p) => p.classList.toggle('active', p.id === `tab-${name}`));
  if (name === 'settings') loadGlobalOptions();
  if (name === 'rules') loadRules();
}

function init() {
  S.addUnits = {
    minSplit: unitInput('size', null, null, '(default)'),
    limit: unitInput('speed', null),
  };
  $('#add-minsplit').append(S.addUnits.minSplit.el);
  $('#add-limit').append(S.addUnits.limit.el);
  $$('.tab').forEach((tab) => tab.addEventListener('click', () => switchTab(tab.dataset.tab)));
  $$('.chip').forEach((chip) => chip.addEventListener('click', () => {
    $$('.chip').forEach((c) => c.classList.toggle('active', c === chip));
    S.filter = chip.dataset.filter;
    for (const [, row] of S.rows) row.remove();
    S.rows.clear();
    $('#downloads').innerHTML = '';
    S.selection.clear();
    renderBulkBar();
    if (S.filter === 'history') loadHistory();
    else { $('#history-bar').hidden = true; renderDownloads(); }
  }));
  $('#btn-history-clear').addEventListener('click', async () => {
    if (!confirm('Forget all recorded downloads? Files on disk are untouched.')) return;
    if (!confirm('Clear the download history?\n\nThis also purges aria2\'s finished '
      + 'results, so completed and failed rows disappear from the Downloads list.')) return;
    const out = await act('/api/history-clear', { method: 'POST' });
    toast(`Cleared ${out.removed} record(s)`
      + (out.purgedAria2Results ? " and aria2's finished results" : ''), 'ok');
    if (out) loadHistory();
  });
  $('#search').addEventListener('input', (e) => { S.search = e.target.value; renderDownloads(); });

  $('#btn-select').addEventListener('click', () => setSelecting(!S.selecting));
  $('#bulk-all').addEventListener('click', () => {
    const visible = visibleDownloads();
    if (S.selection.size >= visible.length) S.selection.clear();
    else for (const d of visible) S.selection.add(d.gid);
    renderBulkBar();
    renderDownloads();
  });
  $('#bulk-pause').addEventListener('click', async () => {
    const out = await bulk('pause', [...S.selection], false);
    if (out?.message) toast(out.message, 'ok');
  });
  $('#bulk-resume').addEventListener('click', async () => {
    const out = await bulk('resume', [...S.selection], false);
    if (out?.message) toast(out.message, 'ok');
  });
  $('#bulk-remove').addEventListener('click', askBulkRemove);
  $('#bulk-cancel').addEventListener('click', () => { $('#bulk-confirm').hidden = true; });
  $('#bulk-keep').addEventListener('click', () => runBulkRemove(true));
  $('#bulk-delete').addEventListener('click', () => runBulkRemove(false));

  $('#btn-add').addEventListener('click', openAdd);
  $('#add-cancel').addEventListener('click', () => $('#add-dialog').close());
  $('#add-submit').addEventListener('click', submitAdd);
  $('#add-dialog').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) submitAdd();
  });

  $('#btn-pause-all').addEventListener('click', () => act('/api/global/pause-all', { method: 'POST' }, 'Paused all'));
  $('#btn-resume-all').addEventListener('click', () => act('/api/global/resume-all', { method: 'POST' }, 'Resumed all'));
  $('#btn-purge').addEventListener('click', () => act('/api/global/purge', { method: 'POST' }, 'Purged finished results'));

  $('#btn-opt-reload').addEventListener('click', loadGlobalOptions);
  $('#btn-opt-save').addEventListener('click', saveGlobalOptions);
  $('#opt-search').addEventListener('input', applyOptionFilter);
  $('#btn-restart-aria2').addEventListener('click', async () => {
    if (!confirm('Restart aria2c? Active downloads pause and resume from the session file.')) return;
    await act('/api/aria2/restart', { method: 'POST' }, 'aria2c restarted');
  });

  $('#rules-speed-source').addEventListener('change', async (e) => {
    await act('/api/rules', { method: 'POST', body: { speed_source: e.target.value } },
      `Rules now judge speed by: ${e.target.selectedOptions[0].textContent}`);
  });
  $('#btn-rule-add').addEventListener('click', addRule);
  $('#btn-rules-save').addEventListener('click', saveRules);
  $('#rules-master').addEventListener('change', async (e) => {
    await act('/api/rules', { method: 'POST', body: { enabled: e.target.checked } },
      e.target.checked ? 'Rules engine on' : 'Rules engine off');
  });
  $('#btn-log-clear').addEventListener('click', () => { S.events = []; renderLog(); });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'n' && !e.ctrlKey && !e.metaKey && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) {
      e.preventDefault();
      openAdd();
    }
  });

  api('/api/config').then((cfg) => { S.config = cfg; }).catch(() => {});
  api('/api/global/options').then((opts) => { S.globalOptions = opts; }).catch(() => {});
  api('/api/log').then((data) => { S.triggers = data.triggers || []; pushEvents(data.events || [], true); }).catch(() => {});
  // Load rules up front so the tab badge is right before the tab is opened.
  loadRules().catch(() => {});

  connect();
}

document.addEventListener('DOMContentLoaded', init);
