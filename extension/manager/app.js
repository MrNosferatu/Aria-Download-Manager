/* Aria Download Manager — the extension's manager page, driven by the manager's
   live state stream. */
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
  pendingOptions: {},     // key -> value saved to config.yaml but not live in aria2
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
  // The "sort into folders" card: what the manager holds, and the edits made
  // here that the page's Save changes will send.
  routing: null,
  routingDirty: false,
  // gid -> true, for the bulk selection mode.
  selection: new Set(),
  selecting: false,
  // gids added with "choose files first": their row (or the row they turn
  // into once a magnet has its metadata) opens by itself.
  openWhenListed: new Set(),
  // Simple shows the few options most people tune; Advanced shows everything.
  // Remembered per surface so each opens the way it was left.
  settingsMode: localStorage.getItem('aria.settingsMode') || 'simple',
  addMode: localStorage.getItem('aria.addMode') || 'simple',
  // How the download list is ordered: 'queue', 'added' or 'finished', and
  // whether that runs forwards. Remembered like the modes above.
  sort: localStorage.getItem('aria.sort') || 'queue',
  sortDesc: localStorage.getItem('aria.sortDesc') === 'true',
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
const fmtDate = (ts) => new Date(ts * 1000).toLocaleString();

function parseSize(value) {
  const text = String(value ?? '').trim();
  if (!text) return null;
  const m = text.match(/^([\d.]+)\s*([kmgt])?i?b?\/?s?$/i);
  if (!m) return Number(text) || null;
  const mult = { k: 1024, m: 1024 ** 2, g: 1024 ** 3, t: 1024 ** 4 }[(m[2] || '').toLowerCase()] || 1;
  return Math.round(parseFloat(m[1]) * mult);
}

/* config.yaml keeps sizes the way you wrote them and aria2 reports them in
   bytes, so `32M` and `33554432` are the same setting spelled two ways. */
function sameOptionValue(live, saved) {
  const a = String(live ?? '').trim();
  const b = String(saved ?? '').trim();
  if (a === b) return true;
  const na = parseSize(a);
  const nb = parseSize(b);
  return na !== null && nb !== null && na === nb;
}

/* ------------------------------------------------------------------ units */
/* aria2 takes speeds and sizes in bytes. These fields are a number and a unit;
   the value stays bytes underneath, and shorthand like 12M still works. */
const UNITS = {
  speed: [['B/s', 1], ['KiB/s', 1024], ['MiB/s', 1024 ** 2], ['GiB/s', 1024 ** 3]],
  size: [['B', 1], ['KiB', 1024], ['MiB', 1024 ** 2], ['GiB', 1024 ** 3]],
};
const DEFAULT_UNIT = 2;

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

function splitUnits(bytes, kind) {
  if (bytes == null) return ['', DEFAULT_UNIT];
  if (bytes === 0) return [kind === 'speed' ? '' : '0', DEFAULT_UNIT];
  const units = UNITS[kind];
  let index = 0;
  while (index < units.length - 1 && bytes >= units[index + 1][1]) index += 1;
  return [String(+(bytes / units[index][1]).toFixed(2)), index];
}

/* One number-and-unit control. read() gives bytes as a string ('' when empty).
   Changing the unit reinterprets the number rather than converting it. An
   untouched field reads back exactly what it was given. */
function unitInput(kind, raw, onEdit, placeholder) {
  const initialBytes = parseSize(raw);
  const [amount, unit] = splitUnits(initialBytes, kind);
  const wrap = document.createElement('span');
  wrap.className = 'unit-input';
  const input = document.createElement('input');
  input.inputMode = 'decimal';
  input.value = amount;
  input.placeholder = placeholder || (kind === 'speed' ? 'No limit' : '0');
  const select = document.createElement('select');
  select.innerHTML = UNITS[kind].map(([label], i) => `<option value="${i}">${label}</option>`).join('');
  select.value = String(unit);
  select.setAttribute('aria-label', 'Unit');
  wrap.append(input, select);

  const read = () => {
    const text = input.value.trim();
    if (text === amount && Number(select.value) === unit) return raw == null ? '' : String(raw);
    if (!text) return kind === 'speed' && raw != null ? '0' : '';
    if (/[a-z]/i.test(text)) {
      const bytes = parseSize(text);
      return bytes == null ? text : String(bytes);
    }
    const number = Number(text);
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
    onError(reason) {
      setPill('Manager offline', 'err', reason);
    },
  });
}

function setPill(text, cls, title = '') {
  const pill = $('#aria2-pill');
  pill.textContent = text;
  pill.className = `status ${cls}`;
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
  const counts = state.counts || {};
  const busy = (counts.active ?? 0) > 0;
  if (aria2.running) {
    setPill(busy ? 'Downloading' : 'Ready', busy ? 'busy' : 'ok',
      `aria2c ${aria2.version || ''} · pid ${aria2.pid ?? 'external'} · ${aria2.rpc_url || ''} · up ${fmtEta(aria2.uptime)}`);
  } else {
    setPill('aria2c is not running', 'err',
      aria2.last_error || 'No aria2c reachable. See the event log under Settings.');
  }

  const g = state.global || {};
  setRate('#stat-down', g.downloadSpeed);
  setRate('#stat-up', g.uploadSpeed);
  const queued = (counts.waiting ?? 0) + (counts.paused ?? 0);
  setStat('#stat-active', counts.active ?? 0);
  setStat('#stat-waiting', queued);
  setStat('#stat-complete', counts.complete ?? 0);
  setStat('#stat-error', counts.error ?? 0);

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

function setRate(sel, value) {
  const node = $(sel);
  node.textContent = fmtSpeed(value);
  node.classList.toggle('quiet', !(Number(value) > 0));
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
/* Inline Material Symbols paths: they inherit currentColor and the button's
   size like any other icon, with nothing to download. */
const ICONS = {
  pause: 'M6 19h4V5H6v14zm8-14v14h4V5h-4z',
  play: 'M8 5v14l11-7z',
  trash: 'M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z',
  close: 'M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z',
  retry: 'M17.65 6.35A7.96 7.96 0 0 0 12 4a8 8 0 1 0 7.73 10h-2.08A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z',
  top: 'M8 11h3v10h2V11h3l-4-4-4 4zM4 3v2h16V3H4z',
  up: 'M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z',
  down: 'M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z',
  open: 'M19 19H5V5h7V3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14c1.1 0 2-.9 2-2v-7h-2v7zM14 3v2h3.59l-9.83 9.83 1.41 1.41L19 6.41V10h2V3h-7z',
  chevron: 'M10 6 8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z',
  check: 'M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z',
  download: 'M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z',
  search: 'M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z',
  wand: 'M7.5 5.6 10 7 8.6 4.5 10 2 7.5 3.4 5 2l1.4 2.5L5 7zm12 9.8L17 14l1.4 2.5L17 19l2.5-1.4L22 19l-1.4-2.5L22 14zM22 2l-2.5 1.4L17 2l1.4 2.5L17 7l2.5-1.4L22 7l-1.4-2.5zm-7.63 5.29a.996.996 0 0 0-1.41 0L1.29 18.96a.996.996 0 0 0 0 1.41l2.34 2.34c.39.39 1.02.39 1.41 0L16.7 11.05a.996.996 0 0 0 0-1.41l-2.33-2.35zm-1.03 5.49-2.12-2.12 2.44-2.44 2.12 2.12-2.44 2.44z',
};

function icon(name) {
  return `<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="${ICONS[name]}"/></svg>`;
}

/* ----------------------------------------------------------- downloads */
const STATUS_TAG = {
  active: 'tag-active', complete: 'tag-complete', error: 'tag-error',
  paused: 'tag-paused', waiting: '', removed: '',
};
// aria2's vocabulary on the wire; what a person reads on the screen.
const STATUS_LABEL = {
  active: 'Active', waiting: 'Queued', paused: 'Paused',
  complete: 'Done', error: 'Failed', removed: 'Removed',
};
const statusLabel = (s) => STATUS_LABEL[s] || capitalise(s);

function visibleDownloads() {
  const all = (S.state?.downloads || []).slice();
  // 'paused' sits with the running downloads rather than below the queue: a
  // rule's brief pause+resume would otherwise make the row dive and jump back.
  const rank = { active: 0, paused: 0, waiting: 1, error: 2, complete: 3, removed: 4 };
  const acting = new Set(
    Object.entries(S.state?.rules?.downloads || {})
      .filter(([, rules]) => Object.values(rules).some((r) => r.acting))
      .map(([gid]) => gid)
  );
  const rankOf = (d) => (acting.has(d.gid) ? 0 : (rank[d.status] ?? 9));
  const byQueue = (a, b) => (rankOf(a) - rankOf(b)) || ((a.queuePosition ?? 0) - (b.queuePosition ?? 0));
  const dir = S.sortDesc ? -1 : 1;
  if (S.sort === 'queue') {
    all.sort((a, b) => dir * byQueue(a, b));
  } else {
    const key = S.sort === 'added' ? 'addedAt' : 'finishedAt';
    all.sort((a, b) => {
      // Nothing to order by (not finished yet) sinks to the end either way,
      // in queue order, rather than flipping to the top when reversed.
      const x = a[key], y = b[key];
      if (x == null || y == null) return (x == null) - (y == null) || byQueue(a, b);
      return dir * (x - y) || byQueue(a, b);
    });
  }
  const needle = S.search.toLowerCase();
  return all.filter((d) => {
    if (S.filter !== 'all' && d.status !== S.filter) return false;
    if (needle && !d.name.toLowerCase().includes(needle)) return false;
    return true;
  });
}

function setEmpty(title, text) {
  const host = $('#empty');
  host.innerHTML = `${icon('download')}<b>${escapeHtml(title)}</b><span>${escapeHtml(text)}</span>`;
}

function renderDownloads() {
  if (S.filter === 'history') return;  // history is rendered from its own fetch
  const list = visibleDownloads();
  const container = $('#downloads');
  $('#empty').hidden = list.length > 0;
  if (!list.length) {
    if (S.search) setEmpty('No match', 'Nothing here has that in its name.');
    else if (S.filter !== 'all') setEmpty(`No ${statusLabel(S.filter).toLowerCase()} downloads`, 'Try another filter.');
    else setEmpty('Nothing here yet', 'Add a download, or start one in the browser and it lands here.');
  }

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
  for (const dl of list) {
    const origin = S.openWhenListed.has(dl.gid) ? dl.gid : dl.following;
    if (!origin || !S.openWhenListed.has(origin) || dl.numFiles < 2) continue;
    S.openWhenListed.delete(origin);
    if (!S.expanded.has(dl.gid)) toggleDetail(dl.gid);
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

  const tags = [`<span class="tag ${STATUS_TAG[dl.status] || ''}">${statusLabel(dl.status)}</span>`];
  if (dl.fileExists === false) tags.push('<span class="tag tag-missing">File missing</span>');
  // The metadata fetch disappears by itself once the torrent it describes
  // starts, so it is labelled for the wait rather than as a download.
  if (dl.isMetadata) tags.push('<span class="tag">Fetching details</span>');
  else if (dl.isTorrent) tags.push('<span class="tag">Torrent</span>');
  if (dl.seeder) tags.push('<span class="tag tag-complete">Seeding</span>');
  const ruleState = S.state?.rules?.downloads?.[dl.gid] || {};
  for (const [name, info] of Object.entries(ruleState)) {
    if (info.acting) tags.push(`<span class="tag tag-rule">${escapeHtml(name)} acting</span>`);
    else if (info.triggers) tags.push(`<span class="tag tag-rule">${escapeHtml(name)} ×${info.triggers}</span>`);
  }
  const tagHtml = tags.join('');
  if (r.badges._html !== tagHtml) { r.badges.innerHTML = tagHtml; r.badges._html = tagHtml; }

  r.fill.style.width = `${dl.progress}%`;
  row.style.setProperty('--p', `${dl.progress}%`);
  r.pick.hidden = !S.selecting;
  r.pick.checked = S.selection.has(dl.gid);
  row.classList.toggle('is-selected', S.selecting && r.pick.checked);

  const bits = [
    `<span class="primary">${fmtBytes(dl.completed)} of ${dl.total ? fmtBytes(dl.total) : '?'}`
    + ` · ${dl.progress.toFixed(1)}%</span>`,
  ];
  if (dl.status === 'active') {
    // aria2's figure is a moving average; the measured one is bytes actually
    // written since the last tick. Both show when they disagree, because that
    // gap is what makes a stall look like it is still running.
    const measured = dl.measuredSpeed;
    const disagrees = measured != null
      && Math.abs(measured - dl.downloadSpeed) > Math.max(65536, dl.downloadSpeed * 0.35);
    bits.push(disagrees
      ? `↓ ${fmtSpeed(measured)} <span title="aria2 reports ${fmtSpeed(dl.downloadSpeed)}: its figure is a moving average and lags by a few seconds">(aria2 says ${fmtSpeed(dl.downloadSpeed)})</span>`
      : `↓ ${fmtSpeed(dl.downloadSpeed)}`);
    if (dl.isTorrent) bits.push(`↑ ${fmtSpeed(dl.uploadSpeed)}`);
    bits.push(`${fmtEta(dl.eta)} left`);
    bits.push(`${dl.connections} connection${dl.connections === 1 ? '' : 's'}`);
    if (dl.isTorrent) bits.push(`${dl.numSeeders} seeders`);
  }
  if (dl.status === 'waiting' && dl.queuePosition != null) bits.push(`#${dl.queuePosition + 1} in queue`);
  if (dl.fileExists === false && dl.path) {
    bits.push(`<span class="err">No longer at ${escapeHtml(dl.path)}</span>`);
  }
  if (dl.errorMessage) bits.push(`<span class="err">${escapeHtml(dl.errorMessage)}</span>`);
  for (const [name, info] of Object.entries(ruleState)) {
    if (info.elapsed > 0 && info.threshold) {
      bits.push(`<span class="rulehint">${escapeHtml(name)} ${info.elapsed.toFixed(1)}/${info.threshold}s</span>`);
    }
  }
  const metaHtml = bits.map((b) => `<span>${b}</span>`).join('');
  if (r.meta._html !== metaHtml) { r.meta.innerHTML = metaHtml; r.meta._html = metaHtml; }

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
   so removing the row and deleting the file are two different intentions. */
function askRemove(dl) {
  const row = S.rows.get(dl.gid);
  if (!row) return;
  const host = $('.dl-confirm', row);
  const gone = dl.fileExists === false;
  host.innerHTML = `<span class="question">${gone
    ? 'The file is already gone. Remove this entry?'
    : 'Remove this download. Keep the file, or delete it too?'}</span>`;
  const cancel = mkBtn2('Cancel', 'btn btn-sm btn-text', () => { host.hidden = true; });
  const keep = mkBtn2('Keep file', 'btn btn-sm',
    () => { host.hidden = true; removeDownload(dl.gid, false, 'Removed, file kept'); });
  const del = mkBtn2('Delete file', 'btn btn-sm btn-danger btn-primary',
    () => { host.hidden = true; removeDownload(dl.gid, true, 'Removed with its file'); });
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

function mkBtn(iconName, title, handler, cls = 'btn btn-icon btn-sm') {
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
    out.push(mkBtn('top', 'Move to the front of the queue',
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
    out.push(mkBtn('retry', 'Download again with the same links and options',
      () => act(`/api/download/${gid}/retry`, { method: 'POST' }, 'Added again')));
  }
  // A download still in flight is being cancelled (a cross); one that has
  // stopped is being thrown away (the bin). A half-written part file is never
  // worth keeping, so cancelling takes it along.
  const live = dl.status === 'active' || dl.status === 'waiting' || dl.status === 'paused';
  out.push(mkBtn(live ? 'close' : 'trash',
    live ? 'Cancel and remove' : 'Remove…',
    () => (live
      ? removeDownload(gid, true, 'Cancelled and cleaned up')
      : askRemove(dl)),
    'btn btn-icon btn-sm btn-danger'));
  return out;
}

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
    row._refs.detail.innerHTML = `<p class="hint err">${escapeHtml(err.message)}</p>`;
    return;
  }
  renderDetail(row._refs.detail, gid, data);
}

function renderDetail(host, gid, data) {
  // The panel is rebuilt every two seconds; doing that under an open
  // dropdown (a file's priority) would snap it shut mid-choice.
  if (document.activeElement?.tagName === 'SELECT' && host.contains(document.activeElement)) return;
  if (!S.detailDrafts.has(gid)) S.detailDrafts.set(gid, {});
  const draft = S.detailDrafts.get(gid);
  const st = data.status || {};
  // aria2 keeps no timestamps; the manager's own record rides on the snapshot.
  const live = (S.state?.downloads || []).find((d) => d.gid === gid);
  const opts = data.options || {};
  const files = data.files || [];
  const active = (data.servers || []).flatMap((s) => (s.servers || []).map((x) => ({ index: s.index, ...x })));

  const pieces = data.pieceMap || [];
  const pieceHtml = pieces.length
    ? `<div><h3>Pieces · ${st.numPieces || 0} × ${fmtBytes(st.pieceLength || 0)}</h3>
       <div class="piecemap">${pieces.map((p) =>
        `<i class="${p >= 100 ? 'done' : p > 0 ? 'part' : ''}"></i>`).join('')}</div></div>`
    : '';

  host.innerHTML = `
    ${pieceHtml}
    <div class="detail-cols">
      <div>
        <h3>About</h3>
        <div class="kv">
          <label>ID</label><code>${gid}</code>
          <label>Status</label><span><span class="tag ${STATUS_TAG[st.status] || ''}">${statusLabel(st.status || '?')}</span></span>
          <label>Folder</label><code>${escapeHtml(st.dir || '')}</code>
          <label>Path</label><code>${escapeHtml(files[0]?.path || '')}</code>
          <label>Size</label><span>${fmtBytes(st.completedLength)} of ${fmtBytes(st.totalLength)}</span>
          <label>Connections</label><span>${st.connections || 0}</span>
          ${live?.addedAt ? `<label>Added</label><span>${fmtDate(live.addedAt)}</span>` : ''}
          ${live?.finishedAt ? `<label>Finished</label><span>${fmtDate(live.finishedAt)}</span>` : ''}
          ${st.infoHash ? `<label>Info hash</label><code>${st.infoHash}</code>` : ''}
          ${st.errorMessage ? `<label>Error</label><span class="err">${escapeHtml(st.errorMessage)} (${st.errorCode})</span>` : ''}
        </div>
        <h3>Options for this download</h3>
        <div data-role="dl-opts"></div>
      </div>
      <div>
        <h3>Files ${files.length > 1 ? `· ${files.length}` : ''}</h3>
        ${files.length > 1 ? `<div class="filehead">
          <span class="hint">Higher priorities finish before lower ones start.</span>
          <label>Set all ${prioritySelect('all', '')}</label>
        </div>` : ''}
        <div class="filelist">
          ${files.map((f) => `
            <div class="filerow${(draft.files?.[f.index] ?? f.priority) === 0 ? ' is-skipped' : ''}">
              <span class="fname" title="${escapeHtml(f.path)}">${escapeHtml(f.path.split('/').pop() || f.path)}</span>
              <span class="fsize">${fmtBytes(f.completedLength)} / ${fmtBytes(f.length)}${f.waitingForTier ? ' · after higher priority' : ''}</span>
              ${files.length > 1 ? prioritySelect(f.index, draft.files?.[f.index] ?? f.priority) : ''}
            </div>`).join('') || '<p class="hint">No file information yet.</p>'}
        </div>
        ${files.length > 1 ? '<button class="btn btn-sm" data-role="save-files" style="margin-top:8px">Apply file choices</button>' : ''}
        <h3>Connections ${active.length ? `· ${active.length}` : ''}</h3>
        <div class="serverlist">
          ${active.map((s) => `
            <div class="filerow">
              <span class="fname" title="${escapeHtml(s.currentUri || s.uri)}">${escapeHtml((s.currentUri || s.uri || '').slice(0, 70))}</span>
              <span class="fsize">${fmtSpeed(s.downloadSpeed)}</span>
            </div>`).join('') || '<p class="hint">No open connections.</p>'}
        </div>
        ${(data.uris || []).length ? `<h3>Links</h3><div class="filelist">${
          data.uris.map((u) => `<div class="filerow"><span class="fname" title="${escapeHtml(u.uri)}">${escapeHtml(u.uri)}</span><span class="fsize">${escapeHtml(u.status)}</span></div>`).join('')
        }</div>` : ''}
        ${(data.peers || []).length ? `<h3>Peers · ${data.peers.length}</h3><div class="filelist">${
          data.peers.slice(0, 25).map((p) => `<div class="filerow"><span class="fname">${escapeHtml(p.ip)}:${p.port}</span><span class="fsize">↓ ${fmtSpeed(p.downloadSpeed)} ↑ ${fmtSpeed(p.uploadSpeed)}</span></div>`).join('')
        }</div>` : ''}
      </div>
    </div>`;

  // Rebuilt every two seconds for the live figures, but what the user is in
  // the middle of editing must survive that: the options block is built once
  // per expansion and moved into each new render, and file ticks are kept.
  const optsHost = $('[data-role="dl-opts"]', host);
  if (!draft.options) draft.options = buildDownloadOptions(gid, opts, Boolean(st.bittorrent));
  optsHost.replaceWith(draft.options);
  const pickers = $$('[data-file]', host).filter((s) => s.dataset.file !== 'all');
  const remember = (sel) => {
    draft.files = draft.files || {};
    draft.files[sel.dataset.file] = Number(sel.value);
    sel.closest('.filerow').classList.toggle('is-skipped', sel.value === '0');
  };
  for (const sel of pickers) sel.addEventListener('change', () => remember(sel));
  $('[data-file="all"]', host)?.addEventListener('change', (e) => {
    if (e.target.value === '') return;
    for (const sel of pickers) { sel.value = e.target.value; remember(sel); }
    e.target.value = '';
  });
  $('[data-role="save-files"]', host)?.addEventListener('click', async () => {
    const levels = Object.fromEntries(pickers.map((s) => [s.dataset.file, Number(s.value)]));
    if (!Object.values(levels).some((v) => v > 0)) { toast('Pick at least one file to download', 'error'); return; }
    await act(`/api/download/${gid}/files`, { method: 'POST', body: { levels } }, 'File choices applied');
    draft.files = null;
  });
}

// qBittorrent's four levels, which is what people coming from it expect.
const PRIORITIES = [[0, 'Do not download'], [1, 'Normal'], [2, 'High'], [3, 'Maximum']];

function prioritySelect(index, value) {
  const blank = value === '' ? '<option value="">Choose…</option>' : '';
  return `<select class="prio" data-file="${index}" aria-label="Priority">${blank}${
    PRIORITIES.map(([v, label]) => `<option value="${v}"${v === value ? ' selected' : ''}>${label}</option>`).join('')
  }</select>`;
}

function buildDownloadOptions(gid, opts, isTorrent) {
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
  for (const [key, label] of [['split', 'Parts'], ['max-connection-per-server', 'Connections per server']]) {
    const input = document.createElement('input');
    input.type = 'number';
    input.min = '1';
    input.value = opts[key] || '';
    fields.push([key, () => input.value.trim(), opts[key] || '']);
    row(label, input);
  }
  const unitRows = {};
  for (const [key, label] of [['max-download-limit', 'Download limit'], ['max-upload-limit', 'Upload limit']]) {
    const unitField = unitInput('speed', opts[key] ?? null);
    fields.push([key, unitField.read, opts[key] || '']);
    row(label, unitField.el);
    unitRows[key] = block.lastElementChild;
  }
  if (isTorrent) {
    // With download-only on, the upload limit is the floor and not the
    // user's to set, so its row goes away rather than showing "1 B/s".
    const everyTorrent = Boolean(S.state?.torrent?.downloadOnly);
    const on = everyTorrent || opts['download-only'] === 'true';
    const { box, input } = boolSwitch(on, false);
    input.disabled = everyTorrent;
    row('Download only, never seed', box);
    if (everyTorrent) {
      const note = document.createElement('small');
      note.className = 'hint';
      note.textContent = 'On for every torrent in Settings';
      block.lastElementChild.querySelector('label').append(document.createElement('br'), note);
    }
    const sync = () => { unitRows['max-upload-limit'].hidden = input.checked; };
    input.addEventListener('change', sync);
    sync();
    if (!everyTorrent) fields.push(['download-only', () => String(input.checked), opts['download-only'] || 'false']);
  }
  const apply = document.createElement('button');
  apply.className = 'btn btn-sm';
  apply.textContent = 'Apply';
  apply.addEventListener('click', async () => {
    const options = {};
    for (const [key, read, original] of fields) {
      const value = read();
      if (value && !sameOptionValue(value, original)) options[key] = value;
    }
    if (!Object.keys(options).length) { toast('Nothing changed'); return; }
    await act(`/api/download/${gid}/options`, { method: 'POST', body: { options } }, 'Applied');
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
function setAddMode(mode) {
  S.addMode = mode;
  localStorage.setItem('aria.addMode', mode);
  $('#add-form').classList.toggle('mode-advanced', mode === 'advanced');
  for (const btn of $$('#add-mode [data-mode]')) btn.setAttribute('aria-pressed', String(btn.dataset.mode === mode));
}

function openAdd() {
  $('#add-download-only').checked = Boolean(S.state?.torrent?.downloadOnly);
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
  // Only sent when it differs from the global setting, which applies anyway.
  if ($('#add-download-only').checked !== Boolean(S.state?.torrent?.downloadOnly)) {
    options['download-only'] = String($('#add-download-only').checked);
  }
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
  if (!file && !uris.length) { toast('Paste a link or pick a torrent file', 'error'); return; }

  const options = collectAddOptions();
  const positionRaw = $('#add-position').value.trim();
  const position = positionRaw === '' ? null : Number(positionRaw);
  // Choosing files: a .torrent is added paused; a magnet (or a .torrent
  // link) fetches its file list first and its real download waits paused.
  const pickFiles = $('#add-pick-files').checked;
  if (pickFiles) options['pause-metadata'] = 'true';
  const paused = $('#add-paused').checked || (pickFiles && Boolean(file));

  let added = null;
  try {
    if (file) {
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).split(',')[1]);
        reader.onerror = () => reject(new Error('could not read the file'));
        reader.readAsDataURL(file);
      });
      const kind = /\.meta(4|link)$/i.test(file.name) ? 'metalink' : 'torrent';
      added = await api('/api/downloads/file', {
        method: 'POST',
        body: { data, kind, filename: file.name, uris, options, position, paused },
      });
    } else {
      added = await api('/api/downloads', {
        method: 'POST',
        body: { uris, options, position, paused, mirrors: $('#add-mirrors').checked },
      });
    }
    if (pickFiles) {
      // Open the new row's files as soon as it (or, for a magnet, the
      // download its metadata turns into) shows up.
      for (const gid of added?.gids || []) S.openWhenListed.add(gid);
      toast(file ? 'Added paused. Choose its files, then resume.'
        : 'Fetching the file list. The torrent will wait paused for your choice.', 'ok');
    } else {
      toast('Added', 'ok');
    }
    $('#add-dialog').close();
    $('#add-uris').value = '';
    $('#add-file').value = '';
  } catch (err) {
    toast(err.message, 'error');
  }
}

/* -------------------------------------------------------------- settings */
/* Simple: what decides how a download behaves. The same eight the DankBar
   widget shows, so both surfaces teach the same starting point. */
const SIMPLE_OPTIONS = [
  ['max-concurrent-downloads', 'Downloads at once', 'number', 'How many run in parallel; the rest wait in the queue.'],
  ['max-connection-per-server', 'Connections per server', 'number', 'Up to 16. More connections usually means faster downloads from one server.'],
  ['split', 'Parts per download', 'number', 'A file is fetched in this many pieces at the same time.'],
  ['max-overall-download-limit', 'Download speed limit', 'text', 'Across every download. Blank means no limit.'],
  ['max-overall-upload-limit', 'Upload speed limit', 'text', 'For torrents. Blank means no limit.'],
  ['download-only', 'Torrents: download only', 'bool', 'Never seed. While a torrent downloads it uploads at most 1 B/s, and it stops the moment it finishes. Overrides the upload limit.'],
  ['continue', 'Resume unfinished files', 'bool', 'Pick up a partial file where it stopped instead of starting over.'],
];

const OPTION_GROUPS = [
  ['Queue and parallelism', [
    ['max-concurrent-downloads', 'Downloads at once', 'number'],
    ['max-connection-per-server', 'Connections per server (up to 16)', 'number'],
    ['split', 'Parts per download', 'number'],
    ['min-split-size', 'Smallest part', 'text'],
    ['optimize-concurrent-downloads', 'Tune parallelism automatically', 'bool'],
  ]],
  ['Speed limits', [
    ['max-overall-download-limit', 'Download limit, all downloads', 'text'],
    ['max-download-limit', 'Download limit, each download', 'text'],
    ['max-overall-upload-limit', 'Upload limit, all downloads', 'text'],
    ['max-upload-limit', 'Upload limit, each download', 'text'],
    ['lowest-speed-limit', 'Give up below this speed', 'text'],
  ]],
  ['Retries and timeouts', [
    ['max-tries', 'Attempts (0 = unlimited)', 'number'],
    ['retry-wait', 'Wait between attempts (s)', 'number'],
    ['timeout', 'Timeout (s)', 'number'],
    ['connect-timeout', 'Connect timeout (s)', 'number'],
    ['max-file-not-found', 'Not-found replies before giving up', 'number'],
  ]],
  ['Disk and files', [
    ['dir', 'Download folder', 'text'],
    ['file-allocation', 'File allocation', 'select:none,prealloc,trunc,falloc'],
    ['disk-cache', 'Disk cache', 'text'],
    ['continue', 'Resume unfinished files', 'bool'],
    ['allow-overwrite', 'Overwrite existing files', 'bool'],
    ['auto-file-renaming', 'Rename duplicates automatically', 'bool'],
    ['remote-time', 'Keep the server\'s timestamps', 'bool'],
  ]],
  ['HTTP', [
    ['user-agent', 'User agent', 'text'],
    ['referer', 'Referer', 'text'],
    ['http-accept-gzip', 'Accept gzip', 'bool'],
    ['all-proxy', 'Proxy for every protocol', 'text'],
    ['check-certificate', 'Verify TLS certificates', 'bool'],
  ]],
  ['BitTorrent', [
    ['download-only', 'Download only, never seed', 'bool', 'Never seed. While a torrent downloads it uploads at most 1 B/s, and it stops the moment it finishes. Overrides the upload limit.'],
    ['follow-torrent', 'Start downloaded torrents automatically', 'bool'],
    ['bt-max-peers', 'Peers per torrent', 'number'],
    ['seed-ratio', 'Seed until this ratio', 'text'],
    ['seed-time', 'Seed for this long (min)', 'text'],
    ['enable-dht', 'Use DHT', 'bool'],
    ['bt-max-open-files', 'Open files at once', 'number'],
  ]],
];

/* A <label>, not a <span>: the checkbox inside is visually hidden, so only a
   wrapping label can deliver a click to it. */
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

/* aria2's option names carry their topic as a prefix, the only structure on
   offer for the ~120 options beyond the curated set. First match wins. */
const ADVANCED_GROUPS = [
  ['BitTorrent', /^(bt-|dht|peer-|seed-|follow-torrent|listen-port|enable-peer-exchange|max-open-files)/],
  ['Metalink', /^(metalink|follow-metalink)/],
  ['HTTP', /^(http|header|user-agent|referer|content-disposition|use-head|enable-http)/],
  ['FTP', /^ftp/],
  ['Proxy', /proxy/],
  ['RPC', /^rpc/],
  ['Logging', /^(log|console-|quiet|summary-interval|show-|truncate-)/],
  ['Disk and files', /^(dir|disk-|file-|save-|no-file-|allow-|auto-file|conf-path|netrc|ca-cert|check-|piece-|hash-|realtime-|remove-control|force-save|auto-save)/],
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
    + (desc ? `<em>${escapeHtml(desc)}</em>` : '')
    + (label === key ? '' : `<small>${key}</small>`)
    + (pending !== undefined ? ' <span class="tag tag-pending">Applies after restart</span>' : '');
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
    note.textContent = unset ? 'Not set' : '';
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
    input.innerHTML = (unset ? '<option value="">Not set</option>' : '')
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

function setSettingsMode(mode) {
  S.settingsMode = mode;
  localStorage.setItem('aria.settingsMode', mode);
  $('#tab-settings').classList.toggle('mode-advanced', mode === 'advanced');
  for (const btn of $$('#settings-mode [data-mode]')) btn.setAttribute('aria-pressed', String(btn.dataset.mode === mode));
  if (S.state) loadGlobalOptions();
}

async function loadGlobalOptions() {
  try {
    S.globalOptions = await api('/api/global/options');
  } catch (err) {
    toast(`Could not read aria2's options: ${err.message}`, 'error');
    return;
  }
  /* aria2 refuses to change most options while it is running: the RPC answers
     OK and keeps the old value. Those edits are still written to config.yaml,
     so a key whose saved value differs from the running one is shown at its
     saved value and marked as waiting for a restart. */
  S.pendingOptions = {};
  if (!S.config) { try { S.config = await api('/api/config'); } catch (err) { /* ignore */ } }
  const saved = (S.config?.aria2?.options) || {};
  for (const [key, value] of Object.entries(saved)) {
    if (key in S.globalOptions && !sameOptionValue(S.globalOptions[key], value)) {
      S.pendingOptions[key] = String(value);
    }
  }
  const note = $('#options-note');
  note.textContent = S.config?.config_path
    ? `Changes apply to the running aria2c right away and are saved to ${S.config.config_path}.`
    : 'Changes apply to the running aria2c right away.';

  S.optInputs.clear();

  // Simple: one card, the essentials.
  const simple = $('#options-simple');
  simple.innerHTML = '';
  if (S.settingsMode !== 'advanced') {
    for (const [key, label, kind, desc] of SIMPLE_OPTIONS) {
      simple.append(optionField(key, label, kind, S.globalOptions[key], desc));
    }
    renderRouting();  // its "dir" field registers with the rest
    return;
  }

  // Advanced: the curated groups, then everything else aria2 reports.
  const groupsHost = $('#options-groups');
  groupsHost.innerHTML = '';
  const covered = new Set();
  for (const [title, opts] of OPTION_GROUPS) {
    const group = document.createElement('div');
    group.className = 'optgroup';
    group.innerHTML = `<h3>${title}</h3>`;
    for (const [key, label, kind, desc] of opts) {
      covered.add(key);
      group.append(optionField(key, label, kind, S.globalOptions[key], desc));
    }
    groupsHost.append(group);
  }
  const advanced = $('#options-advanced');
  advanced.innerHTML = '';
  const rest = Object.keys(S.globalOptions).sort().filter((k) => !covered.has(k));
  const counter = $('#advanced-count');
  if (counter) counter.textContent = ` · ${rest.length}`;
  for (const [title, keys] of groupAdvanced(rest)) {
    const group = document.createElement('div');
    group.className = 'optgroup';
    group.innerHTML = `<h3>${title}</h3>`;
    for (const key of keys) {
      const raw = S.globalOptions[key];
      const kind = (raw === 'true' || raw === 'false') ? 'bool' : 'text';
      group.append(optionField(key, key, kind, raw,
        (typeof OPTION_HELP === 'object' && OPTION_HELP[key]) || ''));
    }
    advanced.append(group);
  }
  applyOptionFilter();
  renderRouting();
}

function applyOptionFilter() {
  const needle = $('#opt-search').value.trim().toLowerCase();
  for (const [key, { wrap }] of S.optInputs) {
    const label = wrap.querySelector('label')?.textContent.toLowerCase() || '';
    wrap.style.display = !needle || key.includes(needle) || label.includes(needle) ? '' : 'none';
  }
  // A group with nothing left to show folds away with its heading.
  for (const group of $$('.optgroup')) {
    const anyVisible = $$('.optfield', group).some((f) => f.style.display !== 'none');
    group.style.display = anyVisible ? '' : 'none';
  }
}

async function saveGlobalOptions() {
  const options = {};
  for (const [key, { read, original }] of S.optInputs) {
    const value = read();
    if (!sameOptionValue(value, original)) options[key] = value;
  }
  // One Save button for the page, so the folder card goes with it.
  const routingChanged = S.routingDirty;
  if (!Object.keys(options).length) {
    if (!routingChanged) { toast('Nothing changed'); return; }
    try {
      await saveRouting();
      toast('Sorting saved', 'ok');
    } catch (err) {
      toast(err.message, 'error');
    }
    return;
  }
  if (routingChanged) {
    try {
      await saveRouting();
    } catch (err) {
      toast(err.message, 'error');
    }
  }
  try {
    const res = await api('/api/global/options', { method: 'POST', body: { options } });
    const live = Object.keys(res.applied || {}).length;
    const later = Object.keys(res.pending || {}).length;
    if (later) {
      toast(live
        ? `${live} applied · ${later} saved, applies after an aria2c restart`
        : `Saved. aria2c will not change ${later === 1 ? 'this' : 'these'} while running; restart it to apply`,
      'ok');
    } else {
      toast(`Applied ${live} change${live === 1 ? '' : 's'}`, 'ok');
    }
    try { S.config = await api('/api/config'); } catch (err) { /* keep the old copy */ }
    await loadGlobalOptions();
  } catch (err) {
    toast(err.message, 'error');
  }
}

function renderProcInfo() {
  const aria2 = S.state?.aria2 || {};
  $('#proc-info').innerHTML = Object.entries({
    Managed: aria2.managed ? 'Yes, started by the manager' : 'No, external process',
    Running: aria2.running ? 'Yes' : 'No',
    PID: aria2.pid ?? '—',
    Version: aria2.version || '—',
    'RPC address': aria2.rpc_url || '—',
    Uptime: fmtEta(aria2.uptime),
    Restarts: aria2.restarts ?? 0,
    'Log file': aria2.log_file || '—',
    'Session file': aria2.session_file || '—',
    'Last error': aria2.last_error || 'None',
  }).map(([k, v]) => `<label>${k}</label><code>${escapeHtml(v)}</code>`).join('');
}

/* ----------------------------------------------------------------- sort */
// Each field starts in the direction people expect of it: the queue from the
// front, dates newest first.
const SORT_DEFAULT_DESC = { queue: false, added: true, finished: true };
const SORT_ICON = {
  up: 'M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z',
  down: 'M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z',
};

function setSort(field, desc = SORT_DEFAULT_DESC[field]) {
  S.sort = field in SORT_DEFAULT_DESC ? field : 'queue';
  S.sortDesc = Boolean(desc);
  try {
    localStorage.setItem('aria.sort', S.sort);
    localStorage.setItem('aria.sortDesc', String(S.sortDesc));
  } catch { /* remembered or not, the list still sorts */ }
  renderSortControl();
  if (S.filter === 'history') renderHistory();
  else renderDownloads();
}

function renderSortControl() {
  const history = S.filter === 'history';
  const select = $('#sort-field');
  // History has no queue: it is ordered by when things finished instead.
  select.querySelector('[value="queue"]').disabled = history;
  const field = history && S.sort === 'queue' ? 'finished' : S.sort;
  const desc = history && S.sort === 'queue' ? true : S.sortDesc;
  select.value = field;
  const btn = $('#sort-dir');
  const words = field === 'queue'
    ? (desc ? 'Back of the queue first' : 'Front of the queue first')
    : (desc ? 'Newest first' : 'Oldest first');
  btn.title = `${words} — click to reverse`;
  btn.setAttribute('aria-label', words);
  $('path', btn).setAttribute('d', desc ? SORT_ICON.down : SORT_ICON.up);
}

function sortHistory(entries) {
  const key = S.sort === 'added' ? 'added_at' : 'finished_at';
  const dir = S.sort === 'queue' || S.sortDesc ? -1 : 1;
  const at = (e) => e[key] ?? e.first_seen ?? 0;
  return entries.slice().sort((a, b) => dir * (at(a) - at(b)));
}

/* --------------------------------------------------------------- routing */
const CATEGORY_LABELS = {
  archive: 'Archives', music: 'Music', video: 'Video', image: 'Images', other: 'Everything else',
};

async function loadRouting() {
  try {
    S.routing = await api('/api/routing');
  } catch (err) {
    return;  // the card stays as it was; the options above still work
  }
  S.routingDirty = false;
  renderRouting();
}

function renderRouting() {
  const data = S.routing;
  if (!data) return;
  // aria2's own download folder leads the card: every folder below is
  // relative to it, so the two belong together. It stays an ordinary option
  // field, saved by the page's Save button like the rest.
  const defaultHost = $('#route-default');
  defaultHost.innerHTML = '';
  defaultHost.append(optionField('dir', 'Download folder', 'text', S.globalOptions.dir,
    'Where downloads go unless a type below sends them elsewhere.'));
  $('#route-enabled').checked = Boolean(data.enabled);
  $('#route-enabled').onchange = (e) => {
    data.enabled = e.target.checked;
    S.routingDirty = true;
  };

  const host = $('#route-folders');
  host.innerHTML = '';
  for (const category of data.categories) {
    const field = optionFieldShell(CATEGORY_LABELS[category] || capitalise(category),
      category === 'other' ? 'Anything no other folder claims' : '');
    const input = document.createElement('input');
    input.value = data.folders[category] ?? '';
    input.placeholder = 'Download folder';
    input.addEventListener('input', () => {
      data.folders[category] = input.value.trim();
      S.routingDirty = true;
    });
    field.append(input);
    host.append(field);
  }

  const extHost = $('#route-extensions');
  extHost.innerHTML = '';
  for (const [category, values] of Object.entries(data.extensions)) {
    const field = optionFieldShell(CATEGORY_LABELS[category] || capitalise(category), '');
    const input = document.createElement('input');
    input.value = values.join(' ');
    input.placeholder = data.defaults.extensions[category].join(' ');
    input.addEventListener('input', () => {
      data.extensions[category] = input.value.split(/[\s,]+/).filter(Boolean);
      S.routingDirty = true;
    });
    field.append(input);
    extHost.append(field);
  }
}

/* The same two-column row the option lists use, without an aria2 key behind it. */
function optionFieldShell(label, desc) {
  const wrap = document.createElement('div');
  wrap.className = 'optfield';
  const lab = document.createElement('label');
  lab.innerHTML = escapeHtml(label) + (desc ? `<em>${escapeHtml(desc)}</em>` : '');
  wrap.append(lab);
  return wrap;
}

async function saveRouting() {
  if (!S.routingDirty || !S.routing) return null;
  const { enabled, folders, extensions } = S.routing;
  const saved = await api('/api/routing', { method: 'POST', body: { enabled, folders, extensions } });
  S.routing = saved;
  S.routingDirty = false;
  renderRouting();
  return saved;
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
    `${s.count || 0} recorded · ${s.completed || 0} finished · ${fmtBytes(s.bytes || 0)} · kept in ${s.file || ''}`;

  const rows = sortHistory(data.entries || []);
  $('#empty').hidden = rows.length > 0;
  if (!rows.length) setEmpty('No history yet', 'Finished downloads are remembered here, even after a restart.');
  host.innerHTML = rows.map((e) => {
    const tag = e.status === 'complete' ? 'tag-complete'
      : e.status === 'error' ? 'tag-error' : '';
    return `<article class="job state-${e.status}">
      <div class="hist-row">
        <span class="job-name">${escapeHtml(e.name || e.key)}</span>
        <span class="tag ${tag}">${statusLabel(e.status)}</span>
        <span class="spacer"></span>
        <span class="job-actions">
          ${e.url ? `<button class="btn btn-icon btn-sm" data-hist="readd" data-key="${escapeHtml(e.key)}" title="Download again" aria-label="Download again">${icon('retry')}</button>` : ''}
          <button class="btn btn-icon btn-sm btn-danger" data-hist="remove" data-key="${escapeHtml(e.key)}" title="Forget this entry" aria-label="Forget this entry">${icon('trash')}</button>
        </span>
      </div>
      <div class="job-meta">
        <span>${fmtBytes(e.completed)}${e.total && e.total !== e.completed ? ` of ${fmtBytes(e.total)}` : ''}</span>
        <span>${e.finished_at ? new Date(e.finished_at * 1000).toLocaleString() : ''}</span>
        ${e.path ? `<span title="${escapeHtml(e.path)}">${escapeHtml(e.dir || '')}</span>` : ''}
        ${e.error ? `<span class="err">${escapeHtml(e.error)}</span>` : ''}
      </div>
    </article>`;
  }).join('');

  for (const btn of $$('[data-hist]', host)) {
    btn.addEventListener('click', async () => {
      const key = btn.dataset.key;
      if (btn.dataset.hist === 'readd') {
        await act('/api/history/readd', { method: 'POST', body: { key } }, 'Added again');
      } else {
        await act('/api/history/remove', { method: 'POST', body: { key } });
      }
      loadHistory();
    });
  }
}

/* ----------------------------------------------------------------- rules */
const KNOWN_STATUSES = ['active', 'waiting', 'paused', 'error', 'complete', 'removed'];

// [path, label, kind, placeholder]. The placeholder is an example or what a
// blank field means, so an empty card still explains itself.
const RULE_FIELDS = [
  ['when.speed_below', 'Speed below', 'speed', 'e.g. 50'],
  ['when.for_seconds', 'For at least (s)', 'number', 'e.g. 3'],
  ['when.min_age_seconds', 'Ignore the first (s)', 'number', 'Grace after start, e.g. 8'],
  ['cooldown_seconds', 'Cooldown (s)', 'number', 'Between fires, e.g. 25'],
  ['resume_after_seconds', 'Resume after (s)', 'number', 'Pause length, e.g. 1.5'],
  ['max_triggers', 'Max times', 'number', '0 = no limit'],
  ['when.min_progress', 'Only past (%)', 'number', 'Blank = from the start'],
  ['when.max_progress', 'Only before (%)', 'number', 'Blank = until the end'],
  ['when.connections_below', 'Connections below', 'number', 'Blank = any'],
  ['when.name_matches', 'Name matches (regex)', 'text', 'Blank = every name, e.g. \\.iso$'],
];

const ACTION_LABEL = {
  pause_resume: 'Pause, then resume',
  force_pause_resume: 'Force pause, then resume',
  restart: 'Restart (remove and add again)',
  set_option: 'Change its options',
  stop: 'Pause and leave it paused',
  log_only: 'Log only, do nothing',
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

  if (!S.rules.length) {
    host.innerHTML = `<p class="empty">${icon('wand')}<b>No actions yet</b><span>A common one pauses and resumes a download that stalls under 50 KiB/s for 3 seconds. Add one to start.</span></p>`;
  }

  S.rules.forEach((rule, index) => {
    const card = document.createElement('div');
    card.className = `rule${rule.enabled === false ? ' disabled' : ''}`;

    const head = document.createElement('div');
    head.className = 'rule-head';
    const { box: toggleBox, input: toggle } = boolSwitch(rule.enabled !== false, false);
    toggleBox.title = 'Action on or off';
    toggle.addEventListener('change', () => { rule.enabled = toggle.checked; renderRules(); });

    const name = document.createElement('input');
    name.className = 'rname';
    name.value = rule.name || '';
    name.placeholder = 'Action name';
    name.addEventListener('change', () => { rule.name = name.value.trim(); });

    const del = mkBtn('trash', 'Delete action', () => {
      S.rules.splice(index, 1);
      renderRules();
    }, 'btn btn-icon btn-sm btn-danger');

    head.append(toggleBox, name, del);
    card.append(head);

    const body = document.createElement('div');
    body.className = 'rule-body';
    card.append(body);

    const action = document.createElement('select');
    action.innerHTML = ACTIONS
      .map((a) => `<option value="${a}">${escapeHtml(actionLabel(a))}</option>`).join('');
    action.value = rule.action || 'pause_resume';
    action.addEventListener('change', () => { rule.action = action.value; renderRules(); });

    const actionField = document.createElement('label');
    actionField.className = 'field rule-action';
    const actionLab = document.createElement('span');
    actionLab.textContent = 'What it does';
    actionField.append(actionLab, action);
    body.append(actionField);

    const grid = document.createElement('div');
    grid.className = 'rule-grid';
    for (const [path, label, kind, placeholder] of RULE_FIELDS) {
      const field = document.createElement('label');
      field.className = 'field';
      const span = document.createElement('span');
      span.textContent = label;
      if (kind === 'speed') {
        const current = getPath(rule, path);
        const unitField = unitInput('speed', current ?? null, () => {
          const value = unitField.read();
          setPath(rule, path, value === '' || !Number.isFinite(Number(value)) ? value : Number(value));
        }, placeholder);
        field.append(span, unitField.el);
        grid.append(field);
        continue;
      }
      const input = document.createElement('input');
      if (kind === 'number') input.type = 'number';
      input.placeholder = placeholder || '';
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
    body.append(grid);

    /* aria2's status vocabulary is a short fixed list, so it is offered as
       chips, the same control the filter bar uses. Anything already saved in
       config.yaml is kept even if it is not a known name. */
    const statuses = document.createElement('div');
    statuses.className = 'field';
    statuses.innerHTML = '<span>Applies to</span>';
    const chosen = ((rule.when || {}).statuses || ['active']).slice();
    const names = KNOWN_STATUSES.concat(chosen.filter((s) => !KNOWN_STATUSES.includes(s)));
    const chipRow = document.createElement('div');
    chipRow.className = 'chiprow';
    for (const st of names) {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = `chip${chosen.includes(st) ? ' active' : ''}`;
      chip.innerHTML = `<span class="check" aria-hidden="true">${icon('check')}</span>${escapeHtml(statusLabel(st))}`;
      chip.addEventListener('click', () => {
        const at = chosen.indexOf(st);
        if (at >= 0) chosen.splice(at, 1); else chosen.push(st);
        const next = chosen.length ? chosen : ['active'];
        setPath(rule, 'when.statuses', next.slice());
        chip.classList.toggle('active', chosen.includes(st));
        if (!chosen.length) renderRules();
      });
      chipRow.append(chip);
    }
    statuses.append(chipRow);
    body.append(statuses);

    /* Torrents and plain downloads fail in different ways, so a rule can be
       aimed at one of them. Stored as aria2-side flags the engine already
       understood (torrent_only / http_only); both chips on means either. */
    const kinds = document.createElement('div');
    kinds.className = 'field';
    kinds.innerHTML = '<span>Download type</span>';
    const kindRow = document.createElement('div');
    kindRow.className = 'chiprow';
    const kindState = () => {
      const when = rule.when || {};
      return { torrent: !when.http_only, normal: !when.torrent_only };
    };
    for (const [key, label] of [['torrent', 'Torrents'], ['normal', 'Normal downloads']]) {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = `chip${kindState()[key] ? ' active' : ''}`;
      chip.innerHTML = `<span class="check" aria-hidden="true">${icon('check')}</span>${label}`;
      chip.addEventListener('click', () => {
        const state = kindState();
        state[key] = !state[key];
        // Neither one selected would mean a rule that can never fire; turning
        // the last one off puts it back to both, as the statuses do.
        if (!state.torrent && !state.normal) { state.torrent = state.normal = true; }
        setPath(rule, 'when.torrent_only', state.torrent && !state.normal ? true : '');
        setPath(rule, 'when.http_only', state.normal && !state.torrent ? true : '');
        renderRules();
      });
      kindRow.append(chip);
    }
    kinds.append(kindRow);
    body.append(kinds);

    const descField = document.createElement('label');
    descField.className = 'field';
    const descLab = document.createElement('span');
    descLab.textContent = 'Note';
    const desc = document.createElement('input');
    desc.className = 'rule-desc';
    desc.placeholder = 'What this action is for (optional)';
    desc.value = rule.description || '';
    desc.addEventListener('change', () => { rule.description = desc.value; });
    descField.append(descLab, desc);
    body.append(descField);

    if (rule.action === 'set_option') {
      const hint = document.createElement('p');
      hint.className = 'hint';
      hint.textContent = '"Change its options" needs an "options" mapping. Add it under Raw JSON below.';
      body.append(hint);
    }

    const details = document.createElement('details');
    details.className = 'rule-json';
    details.innerHTML = '<summary>Raw JSON</summary>';
    const area = document.createElement('textarea');
    area.rows = 10;
    area.value = JSON.stringify(rule, null, 2);
    area.addEventListener('change', () => {
      try {
        S.rules[index] = JSON.parse(area.value);
        renderRules();
      } catch (err) {
        toast(`That is not valid JSON: ${err.message}`, 'error');
      }
    });
    details.append(area);
    body.append(details);

    host.append(card);
  });

  renderTriggers();
}

function renderTriggers() {
  $('#rule-triggers').innerHTML = S.triggers.length
    ? S.triggers.map((t) => `
        <div class="logline rule">
          <time>${fmtTime(t.ts)}</time><span class="lvl">action</span>
          <span class="msg"><b>${escapeHtml(t.rule)}</b> · ${escapeHtml(actionLabel(t.action))} → ${escapeHtml(t.name)} at ${fmtSpeed(t.speed)}${t.detail ? ` (${escapeHtml(t.detail)})` : ''}</span>
        </div>`).join('')
    : '<p class="hint">No action has fired yet.</p>';
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
    toast('Actions saved', 'ok');
    renderRules();
  } catch (err) {
    toast(err.message, 'error');
  }
}

function addRule() {
  S.rules.push({
    name: `action-${S.rules.length + 1}`,
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
  $('#btn-select').classList.toggle('btn-outline', !on);
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

/* Unfinished downloads are cleaned up without asking. Only the finished ones
   in the selection raise the question. */
function askBulkRemove() {
  const rows = selectedRows();
  const finished = rows.filter((d) => d.status === 'complete');
  if (!finished.length) { runBulkRemove(false); return; }
  const rest = rows.length - finished.length;
  $('#bulk-question').textContent =
    `${finished.length} finished. Keep the files?`
    + (rest ? ` (${rest} unfinished will be cleaned up.)` : '');
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
  if (name === 'settings') { loadGlobalOptions(); loadRouting(); }
  if (name === 'rules') loadRules();
}

function init() {
  S.addUnits = {
    minSplit: unitInput('size', null, null, 'Default'),
    limit: unitInput('speed', null),
  };
  $('#add-minsplit').append(S.addUnits.minSplit.el);
  $('#add-limit').append(S.addUnits.limit.el);
  setAddMode(S.addMode);
  setSettingsMode(S.settingsMode);

  $$('.tab').forEach((tab) => tab.addEventListener('click', () => switchTab(tab.dataset.tab)));
  $$('.filterbar .chip').forEach((chip) => chip.addEventListener('click', () => {
    $$('.filterbar .chip').forEach((c) => c.classList.toggle('active', c === chip));
    S.filter = chip.dataset.filter;
    for (const [, row] of S.rows) row.remove();
    S.rows.clear();
    $('#downloads').innerHTML = '';
    S.selection.clear();
    renderBulkBar();
    renderSortControl();
    if (S.filter === 'history') loadHistory();
    else { $('#history-bar').hidden = true; renderDownloads(); }
  }));
  $('#sort-field').addEventListener('change', (e) => setSort(e.target.value));
  $('#sort-dir').addEventListener('click', () => {
    const field = $('#sort-field').value;
    const desc = S.filter === 'history' && S.sort === 'queue' ? true : S.sortDesc;
    setSort(field, !desc);
  });
  renderSortControl();
  $('#btn-history-clear').addEventListener('click', async () => {
    if (!confirm('Forget every recorded download? Files on disk are untouched.')) return;
    if (!confirm('This also clears aria2\'s finished results, so finished and failed rows leave the Downloads list. Continue?')) return;
    const out = await act('/api/history-clear', { method: 'POST' });
    toast(`Cleared ${out.removed} record${out.removed === 1 ? '' : 's'}`
      + (out.purgedAria2Results ? ' and aria2\'s finished results' : ''), 'ok');
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
  for (const btn of $$('#add-mode [data-mode]')) btn.addEventListener('click', () => setAddMode(btn.dataset.mode));
  for (const btn of $$('#settings-mode [data-mode]')) btn.addEventListener('click', () => setSettingsMode(btn.dataset.mode));

  $('#btn-pause-all').addEventListener('click', () => act('/api/global/pause-all', { method: 'POST' }, 'Paused everything'));
  $('#btn-resume-all').addEventListener('click', () => act('/api/global/resume-all', { method: 'POST' }, 'Resumed everything'));
  $('#btn-purge').addEventListener('click', () => act('/api/global/purge', { method: 'POST' }, 'Cleared finished and failed'));

  $('#btn-opt-reload').addEventListener('click', loadGlobalOptions);
  $('#btn-opt-save').addEventListener('click', saveGlobalOptions);
  $('#opt-search').addEventListener('input', applyOptionFilter);
  $('#btn-restart-aria2').addEventListener('click', async () => {
    if (!confirm('Restart aria2c? Active downloads pause and pick up again from the session file.')) return;
    await act('/api/aria2/restart', { method: 'POST' }, 'aria2c restarted');
  });

  $('#rules-speed-source').addEventListener('change', async (e) => {
    await act('/api/rules', { method: 'POST', body: { speed_source: e.target.value } },
      `Speed judged by: ${e.target.selectedOptions[0].textContent}`);
  });
  $('#btn-rule-add').addEventListener('click', addRule);
  $('#btn-rules-save').addEventListener('click', saveRules);
  $('#rules-master').addEventListener('change', async (e) => {
    await act('/api/rules', { method: 'POST', body: { enabled: e.target.checked } },
      e.target.checked ? 'Actions on' : 'Actions off');
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
  loadRules().catch(() => {});

  connect();
}

document.addEventListener('DOMContentLoaded', init);
