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
  // The rules as last saved (JSON), what Discard goes back to.
  rulesSaved: '[]',
  // Each edited action's name on the manager, '' for one not saved yet.
  ruleOrigins: [],
  rulesEnabled: true,
  speedSource: 'hybrid',
  // Which action card is open (-1: none), and whether as JSON.
  openRule: -1,
  ruleJson: false,
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
  // The last minute of total download speed, one sample per frame, for the
  // header's sparkline.
  speeds: [],
  // The download shown in the side pane on a wide window ('' for none).
  paneGid: '',
};

//: Wide enough for rail, list and side pane; narrower falls back to tabs,
//: chips and details that open under their row.
const WIDE = window.matchMedia('(min-width: 1100px)');

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
  const reset = () => { input.value = amount; select.value = String(unit); };
  return { el: wrap, read, reset };
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
      showTrouble(/native host/i.test(reason || '') ? 'host' : 'manager');
    },
  });
}

/* A broken link between the browser and aria2c, said plainly with the fix:
   the native-messaging helper not registered, or the manager not running. */
const TROUBLE = {
  host: {
    title: "The browser can't reach the helper",
    text: 'Register the native-messaging helper once, then restart the browser:',
    cmd: 'python3 -m aria_download_manager --install-native-host',
  },
  manager: {
    title: "The manager isn't running",
    text: 'The helper answered, but nothing is listening on the manager\'s socket. Start it with ./run.sh, or its systemd user unit:',
    cmd: 'systemctl --user start aria-download-manager',
  },
};

function showTrouble(kind) {
  const t = TROUBLE[kind];
  document.body.classList.toggle('offline', !!t);
  $('#trouble').hidden = !t;
  if (!t) return;
  // Last known figures would read as live ones; blank them until state returns.
  setRate('#stat-down', 0);
  $('#stat-down').textContent = '–';
  for (const id of ['#sb-down', '#sb-up', '#sb-left']) $(id).textContent = '';
  $('#trouble-title').textContent = t.title;
  $('#trouble-text').textContent = t.text;
  $('#trouble-cmd').textContent = t.cmd;
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
  showTrouble('');
  const aria2 = state.aria2 || {};
  const counts = state.counts || {};
  const busy = (counts.active ?? 0) > 0;
  if (aria2.running) {
    setPill(`aria2c ${aria2.version || ''}`.trim(), busy ? 'busy' : 'ok',
      `pid ${aria2.pid ?? 'external'} · ${aria2.rpc_url || ''} · up ${fmtEta(aria2.uptime)}`);
  } else {
    setPill('aria2c stopped', 'err',
      aria2.last_error || 'No aria2c reachable. See the event log under Settings.');
  }
  // aria2c down: the error and the fix above the list, which stays as it was.
  $('#aria2-banner').hidden = !!aria2.running;
  $('#aria2-why').textContent = aria2.last_error
    || 'Downloads resume where they were once it is back.';

  const g = state.global || {};
  setRate('#stat-down', g.downloadSpeed);
  setRate('#stat-up', g.uploadSpeed);
  S.speeds.push(Number(g.downloadSpeed) || 0);
  if (S.speeds.length > 60) S.speeds.shift();
  drawSpark();

  const totals = activeTotals(state);
  const eta = humanEta(totals.eta);
  $('#left-cell').hidden = !(totals.left > 0);
  $('#stat-left').textContent = `${fmtBytes(totals.left)}${eta ? ` · ${eta}` : ''}`;
  $('#sb-down').textContent = `↓ ${fmtSpeed(g.downloadSpeed)}`;
  $('#sb-up').textContent = `↑ ${fmtSpeed(g.uploadSpeed)}`;
  $('#sb-left').textContent = totals.left > 0 ? `${fmtBytes(totals.left)} left${eta ? ` · ${eta}` : ''}` : '';

  // One button for Pause all and Resume all: pause while anything runs,
  // resume once nothing does.
  const flip = $('#btn-flip');
  const waiting = (counts.waiting ?? 0) + (counts.paused ?? 0);
  flip.dataset.mode = busy ? 'pause' : 'resume';
  flip.innerHTML = `${icon(busy ? 'pause' : 'play')}<span>${busy ? 'Pause all' : 'Resume all'}</span>`;
  flip.disabled = !aria2.running || (!busy && !waiting);
  $('#btn-purge').disabled = !(counts.stopped > 0);

  setCount('all', counts.total ?? (state.downloads || []).length);
  setCount('active', counts.active ?? 0);
  setCount('waiting', counts.waiting ?? 0);
  setCount('paused', counts.paused ?? 0);
  setCount('complete', counts.complete ?? 0);
  setCount('error', counts.error ?? 0);

  const rules = state.rules || {};
  $('#rules-master').checked = !!rules.enabled;
  const masterChanged = S.rulesEnabled !== !!rules.enabled;
  S.rulesEnabled = !!rules.enabled;
  if (masterChanged) paintRuleCount();
  $('#rail-actions').textContent = rules.enabled ? 'on' : 'off';
  $('#sb-actions').textContent = `Automatic actions ${rules.enabled ? 'on' : 'off'}`;
  $('#master-hint').textContent = rules.enabled
    ? 'Watch running downloads and step in when one stalls.'
    : 'Off — nothing below runs. You can still edit and switch them.';

  renderDownloads();
  renderPane();
  renderProcInfo();
}

//: The header's sparkline: the last minute of download speed, newest right.
function drawSpark() {
  const values = S.speeds;
  const svg = $('#spark');
  if (!svg) return;
  if (values.length < 2) {
    $('.line', svg).setAttribute('d', '');
    $('.area', svg).setAttribute('d', '');
    return;
  }
  const peak = Math.max(1, ...values);
  const step = 200 / 59;
  const x0 = 200 - (values.length - 1) * step;
  const pts = values.map((v, i) => `${(x0 + i * step).toFixed(1)} ${(34 - 32 * (v / peak)).toFixed(1)}`);
  $('.line', svg).setAttribute('d', `M${pts.join(' L')}`);
  $('.area', svg).setAttribute('d', `M${x0.toFixed(1)} 36 L${pts.join(' L')} L200 36 Z`);
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

//: Counts sit on the rail and on the narrow-window chips alike. A filter with
//: nothing in it is dimmed rather than hidden, so the list never reflows.
function setCount(filter, value) {
  for (const node of $$(`[data-count="${filter}"]`)) {
    node.textContent = value ? String(value) : '';
    const host = node.closest('[data-filter]');
    if (host) host.classList.toggle('is-zero', !value && filter !== 'all');
  }
}

/* -------------------------------------------------------------- icons */
/* Inline Material Symbols paths: they inherit currentColor and the button's
   size like any other icon, with nothing to download. */
const ICONS = {
  pause: 'M6 19h4V5H6v14zm8-14v14h4V5h-4z',
  play: 'M8 5v14l11-7z',
  edit: 'M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a1 1 0 0 0 0-1.41l-2.34-2.34a1 1 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z',
  copy: 'M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z',
  trash: 'M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z',
  close: 'M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z',
  retry: 'M17.65 6.35A7.96 7.96 0 0 0 12 4a8 8 0 1 0 7.73 10h-2.08A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z',
  top: 'M8 11h3v10h2V11h3l-4-4-4 4zM4 3v2h16V3H4z',
  up: 'M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z',
  down: 'M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z',
  open: 'M19 19H5V5h7V3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14c1.1 0 2-.9 2-2v-7h-2v7zM14 3v2h3.59l-9.83 9.83 1.41 1.41L19 6.41V10h2V3h-7z',
  chevron: 'M10 6 8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z',
  check: 'M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z',
  folder: 'M20 6h-8l-2-2H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zm0 12H4V8h16v10z',
  more: 'M12 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4zm0 2a2 2 0 1 0 0 4 2 2 0 0 0 0-4zm0 6a2 2 0 1 0 0 4 2 2 0 0 0 0-4z',
  info: 'M11 7h2v2h-2zm0 4h2v6h-2zm1-9a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 18a8 8 0 1 1 0-16 8 8 0 0 1 0 16z',
  link: 'M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7a5 5 0 0 0 0 10h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4a5 5 0 0 0 0-10z',
  download: 'M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z',
  search: 'M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z',
  speed: 'M20.38 8.57l-1.23 1.85a8 8 0 0 1-.22 7.58H5.07A8 8 0 0 1 15.58 6.85l1.85-1.23A10 10 0 0 0 3.35 19a2 2 0 0 0 1.72 1h13.85a2 2 0 0 0 1.74-1 10 10 0 0 0-.27-10.44zm-9.79 6.84a2 2 0 0 0 2.83 0l5.66-8.49-8.49 5.66a2 2 0 0 0 0 2.83z',
  add: 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z',
  remove: 'M19 13H5v-2h14v2z',
  undo: 'M12.5 8c-2.65 0-5.05.99-6.9 2.6L2 7v9h9l-3.62-3.62A7.95 7.95 0 0 1 12.5 10.5c3.54 0 6.55 2.31 7.6 5.5l2.37-.78A10.51 10.51 0 0 0 12.5 8z',
  code: 'M9.4 16.6 4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0 4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z',
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
    // Every empty list says why it is empty and what to do next.
    const EMPTY = {
      all: ['No downloads yet', 'Click a download link on any site, paste one with Add, or right-click a link → Download link.'],
      active: ['Nothing is downloading right now', 'Paused and queued downloads are under their own filters.'],
      waiting: ['The queue is empty', 'Downloads wait here when more are added than run at once.'],
      paused: ['Nothing is paused', ''],
      complete: ['Nothing finished since aria2c started', 'aria2 forgets finished downloads when it restarts. History keeps them.'],
      error: ['Nothing has failed', 'Downloads that stop with an error land here, with the reason and a Retry button.'],
    };
    if (S.search) setEmpty(`Nothing matches “${S.search}”`, 'Older downloads that aria2 no longer holds are in History.');
    else setEmpty(...(EMPTY[S.filter] || EMPTY.all));
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
    figure: $('.dl-figure', row),
    fill: $('.bar-fill', row),
    meta: $('.dl-meta', row),
    actions: $('.dl-actions', row),
    more: $('.dl-more', row),
    detail: $('.dl-detail', row),
    confirm: $('.dl-confirm', row),
    tile: $('.dl-tile', row),
    pick: $('.dl-pick', row),
  };
  row._refs.pick.addEventListener('change', () => {
    if (row._refs.pick.checked) S.selection.add(gid);
    else S.selection.delete(gid);
    renderBulkBar();
    row.classList.toggle('is-selected', row._refs.pick.checked);
  });
  row._refs.tile.addEventListener('click', () => toggleDetail(gid));
  row._refs.name.addEventListener('click', () => toggleDetail(gid));
  row._actionKey = '';
  return row;
}

//: The one badge worth a glance: a missing file, a rule about to act, a torrent.
//: The status itself is the tile's colour and the meta line, not a badge.
function badgesFor(dl) {
  const tags = [];
  if (dl.fileExists === false) tags.push('<span class="tag tag-missing">File missing</span>');
  const ruleState = S.state?.rules?.downloads?.[dl.gid] || {};
  for (const [name, info] of Object.entries(ruleState)) {
    if (info.acting) tags.push(`<span class="tag tag-rule">${escapeHtml(name)} acting</span>`);
    else if (info.elapsed > 0 && info.threshold) {
      const left = Math.max(0, info.threshold - info.elapsed).toFixed(1);
      tags.push(`<span class="tag tag-rule">${escapeHtml(name)} in ${left} s</span>`);
    }
  }
  if (dl.seeder) tags.push('<span class="tag tag-complete">Seeding</span>');
  else if (dl.isTorrent && !dl.isMetadata) tags.push(`<span class="tag">${dl.engine === 'qbittorrent' ? 'qBittorrent' : 'Torrent'}</span>`);
  return tags.length > 2 ? [...tags.slice(0, 1), `<span class="tag">+${tags.length - 1}</span>`] : tags.slice(0, 2);
}

//: Three facts at most — size, speed, time left — or the one sentence that
//: matters: why it failed, that it is connecting, that peers are being asked.
function metaFor(dl) {
  if (dl.status === 'error') return `<span class="err">${escapeHtml(dl.errorMessage || 'Failed')}</span>`;
  if (dl.isMetadata) return `Asking peers for the file list · ${dl.connections || 0} connected`;
  if (dl.status === 'active' && !(dl.completed > 0) && !(dl.downloadSpeed > 0)) return 'Connecting…';
  if (dl.verifyPending || (dl.verifiedLength > 0 && dl.status === 'active' && dl.completed >= dl.total)) {
    const pct = dl.total ? Math.floor((dl.verifiedLength / dl.total) * 100) : 0;
    return `Verifying the file · ${pct}%`;
  }
  const bits = [dl.total ? `${fmtBytes(dl.completed)} of ${fmtBytes(dl.total)}` : fmtBytes(dl.completed)];
  if (dl.status === 'active') {
    // aria2's own figure is a long average that lags a stall; the measured
    // one is what actually arrived. One number, the truer one.
    const measured = dl.engine === 'qbittorrent' ? null : dl.measuredSpeed;
    const disagrees = measured != null
      && Math.abs(measured - dl.downloadSpeed) > Math.max(65536, dl.downloadSpeed * 0.35);
    bits.push(fmtSpeed(disagrees ? measured : dl.downloadSpeed));
    if (dl.eta != null && dl.eta >= 0) bits.push(`${humanEta(dl.eta)} left`);
  }
  if (dl.status === 'waiting') bits.push(dl.queuePosition != null ? `#${dl.queuePosition + 1} in queue` : 'Waiting for a free slot');
  if (dl.status === 'paused') bits.unshift('Paused');
  if (dl.status === 'complete' && dl.finishedAt) bits.push(`finished ${new Date(dl.finishedAt * 1000).toLocaleString()}`);
  if (dl.fileExists === false && dl.path) bits.push(`no longer at ${escapeHtml(dl.path)}`);
  return bits.join(' · ');
}

function updateRow(row, dl) {
  const r = row._refs;
  row.className = `dl is-${dl.status}${dl.fileExists === false ? ' is-missing' : ''}`;
  row.classList.toggle('is-current', S.paneGid === dl.gid && WIDE.matches);
  const shownName = dl.isMetadata ? `Magnet · ${dl.name}` : dl.name;
  if (r.name.textContent !== shownName) {
    r.name.textContent = shownName;
    r.name.title = dl.path || dl.firstUri || dl.name;
  }
  const kind = dl.isMetadata || (dl.isTorrent && !dl.name) ? fileKind('x.torrent') : fileKind(dl.name);
  const tilePath = $('path', r.tile);
  if (tilePath.getAttribute('d') !== kind.path) tilePath.setAttribute('d', kind.path);
  r.tile.title = `${statusLabel(dl.status)} · ${kind.label} — details`;

  const tagHtml = badgesFor(dl).join('');
  if (r.badges._html !== tagHtml) { r.badges.innerHTML = tagHtml; r.badges._html = tagHtml; }
  r.figure.textContent = dl.status === 'complete' ? '' : dl.status === 'waiting' ? '' : `${Math.floor(dl.progress || 0)}%`;

  r.fill.style.width = `${dl.isMetadata ? 30 : dl.progress}%`;
  r.pick.hidden = !S.selecting;
  r.pick.checked = S.selection.has(dl.gid);
  row.classList.toggle('is-selected', S.selecting && r.pick.checked);

  const metaHtml = metaFor(dl);
  if (r.meta._html !== metaHtml) { r.meta.innerHTML = metaHtml; r.meta._html = metaHtml; }

  const key = `${dl.status}|${dl.fileExists}|${dl.isMetadata}`;
  if (row._actionKey !== key) {
    row._actionKey = key;
    r.actions.replaceChildren(...actionsFor(dl));
    if (!r.more.hidden) r.more.replaceChildren(...moreFor(dl));
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
    : 'Remove this download. Keep the file on disk?'}</span>`;
  const cancel = mkBtn2('Cancel', 'btn btn-sm btn-text', () => { host.hidden = true; });
  if (gone) {
    host.append(cancel, mkBtn2('Remove entry', 'btn btn-sm btn-primary',
      () => { host.hidden = true; removeDownload(dl.gid, false, 'Removed'); }));
  } else {
    const keep = mkBtn2('Keep file', 'btn btn-sm btn-primary',
      () => { host.hidden = true; removeDownload(dl.gid, false, 'Removed, file kept'); });
    const del = mkBtn2('Delete file', 'btn btn-sm btn-danger',
      () => { host.hidden = true; removeDownload(dl.gid, true, 'Removed with its file'); });
    host.append(cancel, del, keep);
  }
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

function mkAction(iconName, label, handler, cls = 'btn btn-sm') {
  const btn = document.createElement('button');
  btn.className = cls;
  btn.innerHTML = `${icon(iconName)}<span>${escapeHtml(label)}</span>`;
  btn.title = label;
  btn.addEventListener('click', handler);
  return btn;
}

const post = (path, body, ok) => act(path, { method: 'POST', body }, ok).catch(() => {});

//: The one action that fits the state, labelled — the rest are in ⋮.
function primaryFor(dl) {
  const gid = dl.gid;
  if (dl.isMetadata) return null;
  if (dl.status === 'active') return ['pause', 'Pause', () => post(`/api/download/${gid}/pause`)];
  if (dl.status === 'paused') return ['play', 'Resume', () => post(`/api/download/${gid}/resume`)];
  if (dl.status === 'waiting') {
    return ['top', 'Start next', () => post(`/api/download/${gid}/position`, { pos: 0, how: 'POS_SET' })];
  }
  if (dl.status === 'complete' && dl.fileExists !== false && dl.path) {
    return ['open', 'Open', () => post(`/api/download/${gid}/open`, { folder: false })];
  }
  if (dl.status === 'error') return ['retry', 'Retry', () => post(`/api/download/${gid}/retry`, null, 'Added again')];
  if (dl.status === 'complete' || dl.status === 'removed') {
    return ['retry', 'Again', () => post(`/api/download/${gid}/retry`, null, 'Added again')];
  }
  return null;
}

function actionsFor(dl) {
  const out = [];
  const primary = primaryFor(dl);
  if (primary) out.push(mkAction(primary[0], primary[1], primary[2]));
  out.push(mkBtn('more', 'More actions', () => toggleMore(dl.gid)));
  return out;
}

//: Everything else this row can do, with words. What does not apply to the
//: state is left out rather than greyed.
function moreFor(dl) {
  const gid = dl.gid;
  const out = [];
  const queued = dl.status === 'waiting' || dl.status === 'paused';
  const live = queued || dl.status === 'active';
  if (dl.status === 'waiting') out.push(mkAction('pause', 'Pause', () => post(`/api/download/${gid}/pause`)));
  if (dl.status === 'paused') {
    out.push(mkAction('top', 'Move to front',
      () => post(`/api/download/${gid}/position`, { pos: 0, how: 'POS_SET' })));
  }
  if (queued) {
    out.push(mkAction('up', 'Move up', () => post(`/api/download/${gid}/position`, { pos: -1, how: 'POS_CUR' })));
    out.push(mkAction('down', 'Move down', () => post(`/api/download/${gid}/position`, { pos: 1, how: 'POS_CUR' })));
  }
  if ((dl.dir || dl.path) && dl.fileExists !== false) {
    out.push(mkAction('folder', 'Show in folder', () => post(`/api/download/${gid}/open`, { folder: true })));
  }
  if (dl.firstUri) {
    out.push(mkAction('link', 'Copy link', () => navigator.clipboard.writeText(dl.firstUri)
      .then(() => toast('Link copied', 'ok'), () => {})));
  }
  if (dl.status === 'complete' && dl.fileExists !== false) {
    out.push(mkAction('retry', 'Download again', () => post(`/api/download/${gid}/retry`, null, 'Added again')));
  }
  out.push(mkAction('info', S.expanded.has(gid) || S.paneGid === gid ? 'Hide details' : 'Details', () => {
    toggleMore(gid);
    toggleDetail(gid);
  }));
  // A download still in flight is being cancelled (a cross); one that has
  // stopped is being thrown away (the bin). A half-written part file is never
  // worth keeping, so cancelling takes it along.
  out.push(mkAction(live ? 'close' : 'trash', live ? 'Cancel and remove' : 'Remove…', () => {
    toggleMore(gid);
    if (live) removeDownload(gid, true, 'Cancelled and cleaned up');
    else askRemove(dl);
  }, 'btn btn-sm btn-danger'));
  return out;
}

/* A menu at the pointer, for a right-click: [icon, label, run, danger] rows,
   null for a rule between groups. Any press elsewhere, Escape or a scroll
   closes it. */
function popMenu(x, y, items) {
  document.querySelector('.popmenu')?.remove();
  const menu = document.createElement('div');
  menu.className = 'popmenu';
  menu.setAttribute('role', 'menu');
  for (const item of items) {
    if (!item) {
      menu.append(Object.assign(document.createElement('hr'), {}));
      continue;
    }
    const [ico, label, run, danger] = item;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('role', 'menuitem');
    btn.className = danger ? 'danger' : '';
    btn.innerHTML = `${icon(ico)}<span>${escapeHtml(label)}</span>`;
    btn.addEventListener('click', () => { close(); run(); });
    menu.append(btn);
  }
  document.body.append(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = `${Math.min(x, innerWidth - r.width - 8)}px`;
  menu.style.top = `${y + r.height > innerHeight - 8 ? Math.max(8, y - r.height) : y}px`;
  menu.querySelector('button')?.focus();
  const away = (e) => { if (!menu.contains(e.target)) close(); };
  const key = (e) => { if (e.key === 'Escape') close(); };
  function close() {
    menu.remove();
    document.removeEventListener('pointerdown', away, true);
    document.removeEventListener('keydown', key, true);
    document.removeEventListener('scroll', close, true);
  }
  document.addEventListener('pointerdown', away, true);
  document.addEventListener('keydown', key, true);
  document.addEventListener('scroll', close, true);
}

function toggleMore(gid) {
  const row = S.rows.get(gid);
  if (!row) return;
  const more = row._refs.more;
  // One menu open at a time; opening a second closes the first.
  for (const [other, r] of S.rows) if (other !== gid) r._refs.more.hidden = true;
  if (more.hidden) {
    const dl = (S.state?.downloads || []).find((d) => d.gid === gid);
    if (!dl) return;
    more.replaceChildren(...moreFor(dl));
  }
  more.hidden = !more.hidden;
}

const capitalise = (text) => {
  const s = String(text ?? '');
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
};

const escapeHtml = (text) => String(text ?? '').replace(/[&<>"']/g,
  (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));

/* ------------------------------------------------------------- detail */
function toggleDetail(gid) {
  if (WIDE.matches) {
    // A wide window shows the details beside the list instead of under the row.
    S.paneGid = S.paneGid === gid ? '' : gid;
    S.detailDrafts.delete(gid);
    $('#pane-body').innerHTML = S.paneGid ? '<p class="hint">Loading…</p>' : '';
    renderPane();
    for (const [g, r] of S.rows) r.classList.toggle('is-current', g === S.paneGid);
    if (S.paneGid) refreshPane();
    return;
  }
  const row = S.rows.get(gid);
  if (!row) return;
  const open = S.expanded.has(gid);
  if (open) {
    S.expanded.delete(gid);
    S.detailDrafts.delete(gid);
    row._refs.detail.hidden = true;
    row._refs.tile.classList.remove('open');
  } else {
    S.expanded.add(gid);
    row._refs.detail.hidden = false;
    row._refs.tile.classList.add('open');
    row._refs.detail.innerHTML = '<p class="hint">Loading…</p>';
    refreshDetail(gid);
  }
}

//: The side pane's head: the selected download's tile, name, state and its
//: actions with words. Repainted on every frame; the body refreshes on a timer.
function renderPane() {
  const dl = S.paneGid && (S.state?.downloads || []).find((d) => d.gid === S.paneGid);
  if (S.paneGid && !dl) S.paneGid = '';
  $('#pane-empty').hidden = !!dl;
  $('#pane-head').hidden = !dl;
  $('#pane-body').hidden = !dl;
  if (!dl) return;
  const kind = dl.isMetadata ? fileKind('x.torrent') : fileKind(dl.name);
  $('#pane-tile').className = `dl-tile is-${dl.status}`;
  $('path', $('#pane-tile')).setAttribute('d', kind.path);
  $('#pane-name').textContent = dl.isMetadata ? `Magnet · ${dl.name}` : dl.name;
  $('#pane-name').title = dl.path || dl.name;
  $('#pane-status').innerHTML = `${statusLabel(dl.status)}${dl.status === 'complete' ? '' : ` · ${Math.floor(dl.progress || 0)}%`}`;
  const key = `${dl.gid}|${dl.status}|${dl.fileExists}`;
  if ($('#pane-actions')._key !== key) {
    $('#pane-actions')._key = key;
    const primary = primaryFor(dl);
    const live = ['active', 'waiting', 'paused'].includes(dl.status);
    const buttons = [];
    if (primary) buttons.push(mkAction(primary[0], primary[1], primary[2], 'btn btn-sm btn-tonal'));
    if ((dl.dir || dl.path) && dl.fileExists !== false) {
      buttons.push(mkAction('folder', 'Folder', () => post(`/api/download/${dl.gid}/open`, { folder: true }), 'btn btn-sm btn-outline'));
    }
    buttons.push(mkBtn(live ? 'close' : 'trash', live ? 'Cancel and remove' : 'Remove…', () => {
      if (live) removeDownload(dl.gid, true, 'Cancelled and cleaned up');
      else askRemove(dl);
    }, 'btn btn-icon btn-sm btn-danger'));
    $('#pane-actions').replaceChildren(...buttons);
  }
}

async function refreshPane() {
  const gid = S.paneGid;
  if (!gid) return;
  let data;
  try {
    data = await api(`/api/download/${gid}`);
  } catch (err) {
    $('#pane-body').innerHTML = `<p class="hint err">${escapeHtml(err.message)}</p>`;
    return;
  }
  if (S.paneGid === gid) renderDetail($('#pane-body'), gid, data);
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

/* A download's details, in the order people look for things: what is wrong
   (if anything), its files, its options, and only then the technical record.
   Built once per expansion and refreshed in place every two seconds, so what
   is being edited — a priority menu, a limit being typed — survives. Every
   change saves as it is made; there is no Apply. */
function renderDetail(host, gid, data) {
  if (!S.detailDrafts.has(gid)) S.detailDrafts.set(gid, {});
  const draft = S.detailDrafts.get(gid);
  const st = data.status || {};
  const files = data.files || [];
  const qb = data.engine === 'qbittorrent';
  const isTorrent = Boolean(st.bittorrent);

  if (!host.querySelector('[data-role="d-files"]')) {
    host.innerHTML = `
      <p class="dbanner err" data-role="d-error" hidden></p>
      <section class="dsec" data-role="d-files" hidden>
        <div class="dsec-head">
          <h3>Files</h3>
          <span class="hint" data-role="d-saved"></span>
          <span class="spacer"></span>
          <button class="btn btn-sm btn-primary" data-role="d-start" hidden>Start download</button>
        </div>
        <div data-role="d-tree"></div>
      </section>
      <section class="dsec">
        <div class="dsec-head"><h3>Options</h3><span class="hint" data-role="d-opts-saved"></span></div>
        <div data-role="d-opts"></div>
      </section>
      <details class="dsec dmore" data-role="d-more">
        <summary>Details</summary>
        <div data-role="d-info"></div>
      </details>`;
    draft.tree = null;
    draft.options = null;
    const more = host.querySelector('[data-role="d-more"]');
    more.open = Boolean(draft.moreOpen);
    more.addEventListener('toggle', () => { draft.moreOpen = more.open; });
    host.querySelector('[data-role="d-start"]').addEventListener('click', (e) => {
      e.currentTarget.disabled = true;
      act(`/api/download/${gid}/resume`, { method: 'POST' }, 'Started').catch(() => {});
    });
  }
  const $d = (role) => host.querySelector(`[data-role="${role}"]`);

  // ---- what is wrong, where it cannot be missed
  const error = st.errorMessage ? `${st.errorMessage}${st.errorCode && st.errorCode !== 'qbittorrent' ? ` (${st.errorCode})` : ''}` : '';
  $d('d-error').hidden = !error;
  $d('d-error').textContent = error;

  // ---- files: a tree, like qBittorrent's; saved as it changes
  const many = files.length > 1;
  $d('d-files').hidden = !many;
  if (many) {
    const levels = Object.fromEntries(files.map((f) => [String(f.index), f.priority ?? (f.selected === 'true' ? 1 : 0)]));
    if (!draft.tree) {
      draft.tree = mountFileTree($d('d-tree'), {
        files, base: st.dir || '', levels, progress: true,
        onChange: (next) => saveLevels(gid, draft, next, $d('d-saved')),
      });
    } else {
      draft.tree.update(files, levels);
    }
  }
  // A torrent held for its file choice says how to go on.
  $d('d-start').hidden = !(isTorrent && st.status === 'paused');
  $d('d-start').disabled = false;

  // ---- options, built once
  if (!draft.options) {
    draft.options = buildDownloadOptions(gid, data.options || {}, isTorrent, qb, $d('d-opts-saved'));
    $d('d-opts').replaceChildren(draft.options);
  }

  // ---- the technical record, folded away
  if ($d('d-more').open) $d('d-info').innerHTML = detailInfo(gid, data);
}

// Priorities save half a second after the last change, so a burst of clicks
// is one request.
function saveLevels(gid, draft, levels, status) {
  clearTimeout(draft.saveTimer);
  if (!Object.values(levels).some((v) => Number(v) > 0)) {
    status.textContent = 'Pick at least one file';
    return;
  }
  status.textContent = 'Saving…';
  draft.saveTimer = setTimeout(async () => {
    try {
      await api(`/api/download/${gid}/files`, { method: 'POST', body: { levels } });
      status.textContent = 'Saved';
    } catch (err) {
      status.textContent = '';
      toast(err.message, 'error');
    }
  }, 500);
}

function detailInfo(gid, data) {
  const st = data.status || {};
  const files = data.files || [];
  const live = (S.state?.downloads || []).find((d) => d.gid === gid);
  const active = (data.servers || []).flatMap((s) => (s.servers || []).map((x) => ({ index: s.index, ...x })));
  const pieces = data.pieceMap || [];
  const kv = [
    ['Folder', st.dir],
    ['File', files.length === 1 ? files[0].path : ''],
    ['Size', `${fmtBytes(st.completedLength)} of ${fmtBytes(st.totalLength)}`],
    ['Connections', String(st.connections || 0)],
    ['Added', live?.addedAt ? fmtDate(live.addedAt) : ''],
    ['Finished', live?.finishedAt ? fmtDate(live.finishedAt) : ''],
    ['Info hash', st.infoHash],
    ['ID', gid],
  ].filter(([, v]) => v);
  return `
    <div class="kv">${kv.map(([k, v]) => `<label>${k}</label><code>${escapeHtml(v)}</code>`).join('')}</div>
    ${pieces.length ? `<h4>Pieces · ${st.numPieces || 0} × ${fmtBytes(st.pieceLength || 0)}</h4>
      <div class="piecemap">${pieces.map((p) => `<i class="${p >= 100 ? 'done' : p > 0 ? 'part' : ''}"></i>`).join('')}</div>` : ''}
    ${active.length ? `<h4>Connections · ${active.length}</h4><div class="filelist">${active.map((x) => `
      <div class="filerow"><span class="fname" title="${escapeHtml(x.currentUri || x.uri)}">${escapeHtml((x.currentUri || x.uri || '').slice(0, 90))}</span>
      <span class="fsize">${fmtSpeed(x.downloadSpeed)}</span></div>`).join('')}</div>` : ''}
    ${(data.uris || []).length ? `<h4>${data.engine === 'qbittorrent' ? 'Trackers' : 'Links'}</h4><div class="filelist">${
      data.uris.map((u) => `<div class="filerow"><span class="fname" title="${escapeHtml(u.uri)}">${escapeHtml(u.uri)}</span><span class="fsize">${escapeHtml(u.status)}</span></div>`).join('')}</div>` : ''}
    ${(data.peers || []).length ? `<h4>Peers · ${data.peers.length}</h4><div class="filelist">${
      data.peers.slice(0, 25).map((x) => `<div class="filerow"><span class="fname">${escapeHtml(x.ip)}:${x.port}${x.client ? ` · ${escapeHtml(x.client)}` : ''}</span><span class="fsize">↓ ${fmtSpeed(x.downloadSpeed)} ↑ ${fmtSpeed(x.uploadSpeed)}</span></div>`).join('')}</div>` : ''}`;
}

/* Options in plain words, each saved the moment it changes. The everyday
   ones show; what only matters to someone tuning goes under Advanced. */
function buildDownloadOptions(gid, opts, isTorrent, qb, status) {
  const block = document.createElement('div');
  block.className = 'dopts';
  const save = async (options) => {
    status.textContent = 'Saving…';
    try {
      await api(`/api/download/${gid}/options`, { method: 'POST', body: { options } });
      status.textContent = 'Saved';
    } catch (err) {
      status.textContent = '';
      toast(err.message, 'error');
    }
  };
  const row = (parent, label, hint, control) => {
    const line = document.createElement('div');
    line.className = 'optrow';
    const text = document.createElement('div');
    text.className = 'optlabel';
    text.innerHTML = `<span></span>${hint ? '<small class="hint"></small>' : ''}`;
    text.firstElementChild.textContent = label;
    if (hint) text.lastElementChild.textContent = hint;
    line.append(text, control);
    parent.append(line);
    return line;
  };
  const limit = (parent, key, label) => {
    const field = unitInput('speed', opts[key] ?? null);
    let last = opts[key] || '0';
    field.el.addEventListener('change', () => {
      const value = field.read() || '0';
      if (sameOptionValue(value, last)) return;
      last = value;
      save({ [key]: value });
    });
    return row(parent, label, '', field.el);
  };
  const toggle = (parent, key, label, hint, onChange) => {
    const { box, input } = boolSwitch(opts[key] === 'true', false);
    input.addEventListener('change', () => {
      save({ [key]: String(input.checked) });
      if (onChange) onChange(input.checked);
    });
    return row(parent, label, hint, box);
  };

  limit(block, 'max-download-limit', 'Download speed limit');
  if (isTorrent) {
    const upload = limit(block, 'max-upload-limit', 'Upload speed limit');
    if (S.state?.torrent?.downloadOnly) {
      const note = document.createElement('p');
      note.className = 'hint';
      note.textContent = 'Sharing stops when a download finishes, for every torrent (Settings).';
      block.append(note);
      upload.hidden = true;
    } else {
      const on = opts['download-only'] === 'true';
      upload.hidden = on;
      toggle(block, 'download-only', 'Stop sharing when done',
        'Uploads as little as possible and stops the moment the download finishes.',
        (checked) => { upload.hidden = checked; });
    }
  }

  const advanced = document.createElement('details');
  advanced.className = 'dadvanced';
  advanced.innerHTML = '<summary>Advanced</summary>';
  if (qb) {
    toggle(advanced, 'sequential-download', 'Download in order',
      'Lets you start watching a video before it finishes. Can be slower.');
    toggle(advanced, 'first-last-piece-first', 'First and last pieces first',
      'Helps media players open the file sooner.');
  } else {
    for (const [key, label, hint] of [
      ['max-connection-per-server', 'Connections per server', 'More can be faster; some servers allow few.'],
      ['split', 'Parts', 'How many pieces are fetched at the same time.'],
    ]) {
      const input = document.createElement('input');
      input.type = 'number';
      input.min = '1';
      input.value = opts[key] || '';
      let last = input.value;
      input.addEventListener('change', () => {
        const value = input.value.trim();
        if (!value || value === last) return;
        last = value;
        save({ [key]: value });
      });
      row(advanced, label, hint, input);
    }
  }
  if (advanced.children.length > 1) block.append(advanced);
  return block;
}

setInterval(() => {
  for (const gid of S.expanded) refreshDetail(gid);
  if (S.paneGid) refreshPane();
}, 2000);

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
    + (pending !== undefined ? ' <span class="tag tag-pending">After restart</span>' : '')
    + (desc ? `<em>${escapeHtml(desc)}</em>` : '')
    + (label === key ? '' : `<small>${key}</small>`);
  const original = value ?? '';
  let read;
  let reset;
  let control;
  const mark = () => wrap.classList.toggle('dirty', !sameOptionValue(read(), original));

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
      mark();
    });
    read = () => (unset ? '' : (input.checked ? 'true' : 'false'));
    reset = () => {
      unset = original === '';
      input.checked = original === 'true';
      box.classList.toggle('unset', unset);
      note.textContent = unset ? 'Not set' : '';
    };
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
    input.addEventListener('change', mark);
    read = () => input.value;
    reset = () => { input.value = unset ? '' : original; };
    control = input;
  } else if (UNIT_OPTIONS[key]) {
    const unitField = unitInput(UNIT_OPTIONS[key], original === '' ? null : original, mark);
    read = unitField.read;
    reset = unitField.reset;
    control = unitField.el;
  } else {
    const input = document.createElement('input');
    input.value = original;
    input.addEventListener('input', mark);
    read = () => input.value;
    reset = () => { input.value = original; };
    control = input;
    if (kind === 'number') {
      // A count is nudged more often than typed: − and + either side.
      input.type = 'number';
      input.min = '0';
      control = document.createElement('span');
      control.className = 'stepper';
      const nudge = (by) => {
        input.value = String(Math.max(0, (Number(input.value) || 0) + by));
        input.dispatchEvent(new Event('input', { bubbles: true }));
      };
      control.append(mkBtn('remove', 'Fewer', () => nudge(-1), 'btn btn-icon btn-sm'), input,
        mkBtn('add', 'More', () => nudge(1), 'btn btn-icon btn-sm'));
    }
  }

  const ctl = document.createElement('span');
  ctl.className = 'optctl';
  const undo = mkBtn('undo', `Back to ${original === '' ? 'not set' : original}`, () => {
    reset();
    mark();
    settingsChanged();
  }, 'btn btn-icon btn-sm undo');
  ctl.append(undo, control);

  S.optInputs.set(key, { read, original, wrap, label });
  wrap.append(lab, ctl);
  return wrap;
}

function setSettingsMode(mode) {
  S.settingsMode = mode;
  localStorage.setItem('aria.settingsMode', mode);
  $('#tab-settings').classList.toggle('mode-advanced', mode === 'advanced');
  for (const btn of $$('#settings-mode [data-mode]')) btn.setAttribute('aria-pressed', String(btn.dataset.mode === mode));
  buildToc();
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
    settingsChanged();
    return;
  }

  // Advanced: the curated groups, then everything else aria2 reports.
  const groupsHost = $('#options-groups');
  groupsHost.innerHTML = '';
  const covered = new Set();
  OPTION_GROUPS.forEach(([title, opts], i) => {
    const group = document.createElement('section');
    group.className = 'optgroup';
    group.id = `set-group-${i}`;
    group.dataset.toc = title;
    group.innerHTML = `<h3>${title}</h3>`;
    for (const [key, label, kind, desc] of opts) {
      covered.add(key);
      group.append(optionField(key, label, kind, S.globalOptions[key], desc));
    }
    groupsHost.append(group);
  });
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
  buildToc();
  settingsChanged();
}

/* --------------------------------------------- settings: save bar, nav */
//: An option's value as the save bar says it: "16", "2.0 MiB/s", "not set".
function optionWordsFor(key, value) {
  if (value === '' || value == null) return 'not set';
  const unit = UNIT_OPTIONS[key];
  if (unit && /^\d+$/.test(String(value))) {
    if (unit === 'speed') return Number(value) ? fmtSpeed(Number(value)) : 'no limit';
    return fmtBytes(Number(value));
  }
  return String(value);
}

function settingsChanged() {
  const changes = [];
  for (const [key, { read, original, label }] of S.optInputs) {
    const now = read();
    if (!sameOptionValue(now, original)) changes.push(`${label} ${optionWordsFor(key, original)} → ${optionWordsFor(key, now)}`);
  }
  if (S.routingDirty) changes.push('Folders & sorting');
  const n = changes.length;
  $('#settings-savebar').hidden = n === 0;
  $('#settings-dirty').textContent = n === 1
    ? `1 unsaved change · ${changes[0]}`
    : `${n} unsaved changes`;
  $('#settings-dirty').title = changes.join('\n');
}

async function discardSettings() {
  S.routingDirty = false;
  await loadRouting();
  await loadGlobalOptions();
}

/* The section list down the left: built from the cards shown in the current
   mode, so Simple lists three and Advanced lists them all. */
function buildToc() {
  const toc = $('#settings-toc');
  if (!toc) return;
  const sections = $$('#tab-settings [data-toc]');
  const errors = S.events.filter((e) => e.level === 'error').length;
  toc.replaceChildren(...sections.filter(visibleInMode).map((el) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'nav';
    btn.dataset.target = el.id;
    btn.textContent = el.dataset.toc;
    if (el.id === 'set-log' && errors) {
      const n = document.createElement('span');
      n.className = 'n bad';
      n.textContent = `${errors} error${errors === 1 ? '' : 's'}`;
      btn.append(n);
    }
    btn.addEventListener('click', () => {
      if (el.tagName === 'DETAILS') el.open = true;
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
    return btn;
  }));
  // After layout: until the cards fill in, the page is short enough to read as scrolled to the end.
  requestAnimationFrame(spyToc);
}

//: Whether a section shows in the current Simple / Advanced mode.
function visibleInMode(el) {
  const level = el.closest('[data-level]')?.dataset.level;
  if (el.id === 'set-basics') return S.settingsMode !== 'advanced';
  return level !== 'advanced' || S.settingsMode === 'advanced';
}

//: Marks the section at the top of the window in the list.
function spyToc() {
  const buttons = $$('#settings-toc .nav');
  if (!buttons.length) return;
  const head = $('.masthead')?.offsetHeight || 0;
  let current = buttons[0];
  // At the very bottom the last sections can't reach the top; the last one is it.
  const atEnd = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
  if (atEnd) current = buttons[buttons.length - 1];
  else for (const btn of buttons) {
    const el = document.getElementById(btn.dataset.target);
    if (el && el.getBoundingClientRect().top - head < 120) current = btn;
  }
  for (const btn of buttons) btn.classList.toggle('active', btn === current);
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

// Which engine downloads torrents, in one line.
function torrentEngineText(qb) {
  if (!qb || !qb.wanted) return 'aria2c';
  if (qb.running) return `qBittorrent ${qb.version || ''} · ${qb.url || ''}`;
  return `aria2c (qBittorrent unavailable: ${qb.last_error || 'not running'})`;
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
    Torrents: torrentEngineText(S.state?.qbittorrent),
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

// A category's tile: the same file-kind icons the download rows use.
const CATEGORY_KIND = { archive: 'archive', music: 'audio', video: 'video', image: 'picture', other: 'file' };

function renderRouting() {
  const data = S.routing;
  if (!data) return;
  // aria2's own download folder leads the card: every folder below is
  // relative to it, so the two belong together. It stays an ordinary option
  // field, saved with the rest.
  const defaultHost = $('#route-default');
  defaultHost.innerHTML = '';
  defaultHost.append(optionField('dir', 'Download folder', 'text', S.globalOptions.dir,
    'Where downloads go unless a type below sends them elsewhere.'));
  $('#route-enabled').checked = Boolean(data.enabled);
  $('#route-enabled').onchange = (e) => {
    data.enabled = e.target.checked;
    S.routingDirty = true;
    $('#route-folders').classList.toggle('off', !data.enabled);
  };

  /* One row per type: its folder, then the extensions that count as it, as
     chips — × takes one out, typing and Enter puts one in. */
  const host = $('#route-folders');
  host.classList.toggle('off', !data.enabled);
  host.innerHTML = '';
  const dirty = () => { S.routingDirty = true; settingsChanged(); };
  for (const category of data.categories || Object.keys(data.folders || {})) {
    const row = document.createElement('div');
    row.className = 'route';
    const kind = FILE_KINDS[CATEGORY_KIND[category] || 'file'];
    const head = document.createElement('div');
    head.className = 'route-head';
    head.innerHTML = `<span class="dl-tile kind-${CATEGORY_KIND[category] || 'file'}"><svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="${kind[1]}"/></svg></span>
      <b>${escapeHtml(CATEGORY_LABELS[category] || capitalise(category))}</b><span class="arrow">→</span>`;
    const input = document.createElement('input');
    input.value = data.folders[category] ?? '';
    input.placeholder = category === 'other' ? 'The download folder' : 'Subfolder';
    input.setAttribute('aria-label', `Folder for ${CATEGORY_LABELS[category] || category}`);
    input.addEventListener('input', () => { data.folders[category] = input.value.trim(); dirty(); });
    head.append(input);
    row.append(head);

    if (category !== 'other' && data.extensions) {
      const chips = document.createElement('div');
      chips.className = 'chiprow route-exts';
      const paint = () => {
        const list = data.extensions[category] || [];
        const nodes = list.map((ext) => {
          const chip = document.createElement('span');
          chip.className = 'chip removable';
          chip.textContent = ext;
          const x = document.createElement('button');
          x.type = 'button';
          x.className = 'x';
          x.textContent = '×';
          x.setAttribute('aria-label', `Remove ${ext}`);
          x.addEventListener('click', () => {
            data.extensions[category] = list.filter((e) => e !== ext);
            paint();
            dirty();
          });
          chip.append(x);
          return chip;
        });
        const add = document.createElement('input');
        add.className = 'chip-input';
        add.placeholder = '+ add';
        add.setAttribute('aria-label', `Add an extension to ${CATEGORY_LABELS[category] || category}`);
        const take = () => {
          const items = add.value.split(/[\s,]+/).map((v) => v.trim().replace(/^\*?\./, '').toLowerCase()).filter(Boolean);
          if (!items.length) return;
          data.extensions[category] = [...new Set([...(data.extensions[category] || []), ...items])];
          paint();
          dirty();
          chips.querySelector('.chip-input')?.focus();
        };
        add.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ',') { e.preventDefault(); take(); }
        });
        add.addEventListener('blur', take);
        chips.replaceChildren(...nodes, add);
      };
      paint();
      row.append(chips);
    }
    host.append(row);
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
  settingsChanged();
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
  // Same shape as a download row: tile, name, one line, one action and the
  // rest beside it — Open when the file is there, Again when it is not.
  host.innerHTML = rows.map((e) => {
    const kind = fileKind(e.name || e.key);
    const missing = e.file_exists === false;
    const failed = e.status === 'error';
    const meta = [
      `${fmtBytes(e.completed)}${e.total && e.total !== e.completed ? ` of ${fmtBytes(e.total)}` : ''}`,
      e.finished_at ? new Date(e.finished_at * 1000).toLocaleString() : '',
      e.dir ? escapeHtml(e.dir.replace(/^\/home\/[^/]+/, '~')) : '',
    ].filter(Boolean).join(' · ');
    const key = escapeHtml(e.key);
    const primary = failed || missing
      ? (e.url ? `<button class="btn btn-sm" data-hist="readd" data-key="${key}">${icon('retry')}${failed ? 'Retry' : 'Again'}</button>` : '')
      : `<button class="btn btn-sm" data-hist="open" data-key="${key}">${icon('open')}Open</button>`;
    return `<article class="dl is-${failed ? 'error' : missing ? 'missing' : 'complete'}">
      <div class="dl-main">
        <span class="dl-tile" aria-hidden="true"><svg class="ico" viewBox="0 0 24 24"><path d="${kind.path}"/></svg></span>
        <div class="dl-body">
          <div class="dl-title"><span class="dl-name" title="${escapeHtml(e.path || e.name || '')}">${escapeHtml(e.name || e.key)}</span>
            <span class="dl-badges">${missing ? '<span class="tag tag-missing">File missing</span>' : ''}</span></div>
          <div class="dl-meta">${failed ? `<span class="err">${escapeHtml(e.error || 'Failed')}</span>` : meta}</div>
        </div>
        <div class="dl-actions">
          ${primary}
          ${!missing && !failed ? `<button class="btn btn-icon btn-sm" data-hist="folder" data-key="${key}" title="Show in folder" aria-label="Show in folder">${icon('folder')}</button>` : ''}
          <button class="btn btn-icon btn-sm btn-danger" data-hist="remove" data-key="${key}" title="Forget this entry" aria-label="Forget this entry">${icon('trash')}</button>
        </div>
      </div>
    </article>`;
  }).join('');

  for (const btn of $$('[data-hist]', host)) {
    btn.addEventListener('click', async () => {
      const key = btn.dataset.key;
      const what = btn.dataset.hist;
      try {
        if (what === 'readd') await act('/api/history/readd', { method: 'POST', body: { key } }, 'Added again');
        else if (what === 'open') await act('/api/history/open', { method: 'POST', body: { key, folder: false } });
        else if (what === 'folder') await act('/api/history/open', { method: 'POST', body: { key, folder: true } });
        else await act('/api/history/remove', { method: 'POST', body: { key } });
      } catch { return; }
      if (what === 'readd' || what === 'remove') loadHistory();
    });
  }
}

/* ----------------------------------------------------------------- rules */
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

/* An action reads as one sentence with its values inline, worded as the
   DankBar's editor words it (dms-plugin/lib/Rules.js), so both read alike:
   "When an active download of any kind stays below 50 KiB/s for 3 s, pause,
   then resume it after 1.5 s." The rarer conditions are removable chips. */
const ACTION_WORDS = {
  pause_resume: 'pause, then resume it',
  force_pause_resume: 'force-pause, then resume it',
  restart: 'remove it and add it again',
  set_option: 'change its options',
  stop: 'pause it and leave it paused',
  log_only: 'only log it',
};
const ACTION_DONE = {
  pause_resume: 'paused and resumed',
  force_pause_resume: 'force-paused and resumed',
  restart: 'restarted',
  set_option: 'options changed',
  stop: 'paused',
  log_only: 'logged',
};
const RESUMES = new Set(['pause_resume', 'force_pause_resume']);

// [statuses, words]. A saved list that is none of these is offered as itself.
const STATUS_CHOICES = [
  [['active'], 'an active'],
  [['waiting'], 'a queued'],
  [['active', 'waiting'], 'an active or queued'],
  [['paused'], 'a paused'],
];
const KIND_CHOICES = [['any', 'of any kind'], ['torrent', 'that is a torrent'], ['http', 'that is not a torrent']];

// [path, words before, words after, value it starts at, input kind]
const RULE_EXTRAS = [
  ['when.min_age_seconds', 'Ignore the first', 's', 8, 'number'],
  ['cooldown_seconds', 'Cooldown', 's', 25, 'number'],
  ['max_triggers', 'At most', 'times', 20, 'number'],
  ['when.min_progress', 'Only past', '%', 5, 'number'],
  ['when.max_progress', 'Only before', '%', 95, 'number'],
  ['when.connections_below', 'Fewer than', 'connections', 2, 'number'],
  ['when.name_matches', 'Name matches', '', '\\.iso$', 'text'],
];

// The empty tab's starting points; each is added and opened in one click.
const RULE_TEMPLATES = [
  { icon: 'speed', title: 'Kick stalled downloads', rule: {
    name: 'Stall kick', enabled: true, description: 'Pause and resume a download that stalls',
    when: { statuses: ['active'], speed_below: 51200, for_seconds: 3, min_age_seconds: 8 },
    action: 'pause_resume', resume_after_seconds: 1.5, cooldown_seconds: 25, max_triggers: 20 } },
  { icon: 'retry', title: 'Restart dead torrents', rule: {
    name: 'Dead torrent', enabled: true, description: 'Start a torrent over when it stops getting data',
    when: { statuses: ['active'], torrent_only: true, speed_below: 1024, for_seconds: 120, min_progress: 5 },
    action: 'restart', cooldown_seconds: 600, max_triggers: 3 } },
  { icon: 'down', title: 'Slow down big files', rule: {
    name: 'Slow ISOs', enabled: true, description: 'Keep disk images from taking the whole line',
    when: { statuses: ['active'], name_matches: '\\.iso$', speed_above: 2097152, for_seconds: 5 },
    action: 'set_option', options: { 'max-download-limit': '2M' }, max_triggers: 1 } },
];

const blank = (v) => v === undefined || v === null || v === '';

// What a set_option action sets, in words where the option is a common one.
function optionWords(options) {
  return Object.entries(options).map(([key, value]) => {
    if (key === 'max-download-limit') return `limit it to ${fmtSpeed(parseSize(value) || 0)}`;
    if (key === 'max-upload-limit') return `limit its uploads to ${fmtSpeed(parseSize(value) || 0)}`;
    if (key === 'max-connection-per-server') return `use ${value} connections per server`;
    return `set ${key} = ${value}`;
  }).join(', ');
}

// "Under 50 KiB/s for 3 s → pause, then resume it after 1.5 s"
function ruleSummary(rule) {
  const when = rule.when || {};
  const lead = [];
  if (when.torrent_only) lead.push('Torrents');
  else if (when.http_only) lead.push('Normal downloads');
  if (when.name_matches) lead.push(`named /${when.name_matches}/`);
  let cond = '';
  if (!blank(when.speed_below)) cond = `under ${fmtSpeed(Number(when.speed_below))}`;
  else if (!blank(when.speed_above)) cond = `over ${fmtSpeed(Number(when.speed_above))}`;
  else if (!blank(when.connections_below)) cond = `under ${when.connections_below} connections`;
  if (when.for_seconds) cond += ` for ${when.for_seconds} s`;
  if (when.min_progress) cond += ` past ${when.min_progress}%`;
  let action = rule.action === 'set_option' && Object.keys(rule.options || {}).length
    ? optionWords(rule.options)
    : ACTION_WORDS[rule.action || 'pause_resume'] || actionLabel(rule.action);
  if (RESUMES.has(rule.action || 'pause_resume') && rule.resume_after_seconds) action += ` after ${rule.resume_after_seconds} s`;
  const head = capitalise((lead.length ? `${lead.join(', ')}: ` : '') + cond.trim());
  return `${head || 'Always'} → ${action}`;
}

function triggerText(t) {
  // A log line already says what was done: "[Stall kick] paused and resumed debian.iso".
  if (t.logLine) return `${String(t.name).replace(/^\[[^\]]*\]\s*/, '')} · ${fmtSpeed(t.speed)}`;
  const done = ACTION_DONE[t.action] || String(t.action || '').replace(/_/g, ' ');
  return `${t.name} · ${fmtSpeed(t.speed)}${done ? ` → ${done}` : ''}${t.detail ? ` (${t.detail})` : ''}`;
}

/* -------------------------------------------------------- load and save */
async function loadRules() {
  try {
    const data = await api('/api/rules');
    S.rules = data.rules || [];
    S.rulesSaved = JSON.stringify(S.rules);
    S.ruleOrigins = S.rules.map((r) => r.name);
    S.rulesEnabled = !!data.enabled;
    S.speedSource = data.speed_source || 'hybrid';
    S.triggers = data.triggers || S.triggers;
    $('#rules-master').checked = S.rulesEnabled;
    paintMeasure();
    renderRules();
  } catch (err) {
    toast(err.message, 'error');
  }
}

function paintMeasure() {
  for (const btn of document.querySelectorAll('#rules-measure [data-source]')) {
    btn.setAttribute('aria-pressed', String(btn.dataset.source === S.speedSource));
  }
}

/* Unsaved edits show as a bar with Save and Discard, and only then; it names
   the action when just one changed. */
function rulesChanged() {
  const saved = JSON.parse(S.rulesSaved || '[]');
  const changed = S.rules.filter((rule, i) => JSON.stringify(rule) !== JSON.stringify(saved[i]));
  const removed = Math.max(0, saved.length - S.rules.length);
  const n = changed.length + removed;
  $('#rules-savebar').hidden = n === 0;
  $('#rules-dirty').textContent = n === 1 && changed.length === 1
    ? `Unsaved changes to ${changed[0].name || 'an action'}`
    : `${n} unsaved change${n === 1 ? '' : 's'}`;
}

async function saveRules() {
  try {
    const data = await api('/api/rules', { method: 'POST', body: { rules: S.rules } });
    S.rules = data.rules;
    S.rulesSaved = JSON.stringify(S.rules);
    S.ruleOrigins = S.rules.map((r) => r.name);
    toast('Actions saved', 'ok');
    renderRules();
  } catch (err) {
    toast(err.message, 'error');
  }
}

function discardRules() {
  S.rules = JSON.parse(S.rulesSaved || '[]');
  S.ruleOrigins = S.rules.map((r) => r.name);
  S.openRule = Math.min(S.openRule ?? -1, S.rules.length - 1);
  renderRules();
}

/* The switch on a row saves straight away, like the master switch, and is
   never one of the unsaved edits: the saved copy changes with it. Only an
   action that is not on the manager yet waits for Save with the rest. */
async function setRuleEnabled(index, on) {
  S.rules[index].enabled = on;
  const name = S.ruleOrigins[index];
  if (name) {
    try {
      await api(`/api/rules/${encodeURIComponent(name)}/toggle`, { method: 'POST', body: { enabled: on } });
      const saved = JSON.parse(S.rulesSaved || '[]');
      for (const rule of saved) if (rule.name === name) rule.enabled = on;
      S.rulesSaved = JSON.stringify(saved);
      toast(`${on ? 'On' : 'Off'}: ${name}`, 'ok');
    } catch (err) {
      S.rules[index].enabled = !on;
      toast(err.message, 'error');
    }
  }
  renderRules();
}

function duplicateRule(index) {
  const copy = structuredClone(S.rules[index]);
  copy.name = uniqueRuleName(`${copy.name} copy`);
  S.rules.splice(index + 1, 0, copy);
  S.ruleOrigins.splice(index + 1, 0, '');
  if (S.openRule > index) S.openRule += 1;
  renderRules();
}

function removeRule(index) {
  S.rules.splice(index, 1);
  S.ruleOrigins.splice(index, 1);
  if (S.openRule === index) S.openRule = -1;
  else if (S.openRule > index) S.openRule -= 1;
  renderRules();
}

function uniqueRuleName(base) {
  const names = new Set(S.rules.map((r) => r.name));
  if (!names.has(base)) return base;
  let n = 2;
  while (names.has(`${base} ${n}`)) n += 1;
  return `${base} ${n}`;
}

function addRule(template = RULE_TEMPLATES[0].rule) {
  const rule = structuredClone(template);
  rule.name = uniqueRuleName(rule.name);
  S.rules.push(rule);
  S.ruleOrigins.push('');
  S.openRule = S.rules.length - 1;
  renderRules();
}

/* ------------------------------------------------------------- render */
function renderRules() {
  const host = $('#rules-list');
  host.innerHTML = '';
  if (!S.rules.length) host.append(ruleTemplates());
  S.rules.forEach((rule, index) => host.append(ruleCard(rule, index)));
  paintRuleCount();
  rulesChanged();
}

//: "3 of 4 on", and while the master switch is off, that none run.
function paintRuleCount() {
  $('#rules-list').classList.toggle('dimmed', !S.rulesEnabled);
  const on = S.rules.filter((r) => r.enabled !== false).length;
  $('#rules-count').textContent = S.rules.length
    ? `${on} of ${S.rules.length} on${S.rulesEnabled ? '' : ' · none run while automatic actions are off'}`
    : 'None yet';
}

function ruleTemplates() {
  const box = document.createElement('div');
  box.className = 'card rule-empty';
  box.innerHTML = `<div class="rule-empty-head">${icon('wand')}<b>Let the manager babysit downloads</b>
    <span class="hint">Start from one of these — each opens ready to edit.</span></div>`;
  for (const t of RULE_TEMPLATES) {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'rule-template';
    row.innerHTML = `<span class="tile">${icon(t.icon)}</span>
      <span class="text"><b>${escapeHtml(t.title)}</b><span class="hint">${escapeHtml(ruleSummary(t.rule))}</span></span>${icon('add')}`;
    row.addEventListener('click', () => addRule(t.rule));
    box.append(row);
  }
  return box;
}

function ruleCard(rule, index) {
  const open = S.openRule === index;
  const card = document.createElement('div');
  card.className = `rule${rule.enabled === false ? ' disabled' : ''}${open ? ' open' : ''}`;

  const head = document.createElement('div');
  head.className = 'rule-head';
  const { box: toggleBox, input: toggle } = boolSwitch(rule.enabled !== false, false);
  toggleBox.title = 'Action on or off';
  toggle.setAttribute('aria-label', `${rule.name || 'Action'} on or off`);
  toggle.addEventListener('change', () => setRuleEnabled(index, toggle.checked));
  head.append(toggleBox);

  if (open) {
    const name = document.createElement('input');
    name.className = 'rname';
    name.value = rule.name || '';
    name.placeholder = 'Action name';
    name.setAttribute('aria-label', 'Action name');
    name.addEventListener('input', () => { rule.name = name.value.trim(); rulesChanged(); });
    head.append(name,
      mkBtn('code', 'Edit as JSON', () => { S.ruleJson = !S.ruleJson; renderRules(); },
        `btn btn-icon btn-sm${S.ruleJson ? ' on' : ''}`),
      mkBtn('trash', 'Delete action', () => removeRule(index), 'btn btn-icon btn-sm btn-danger'));
  } else {
    // The whole row opens the editor; right-click offers the rest.
    const text = document.createElement('button');
    text.type = 'button';
    text.className = 'rule-fold';
    text.innerHTML = `<span class="rule-name"><b>${escapeHtml(rule.name || 'Unnamed action')}</b>${
      rule.enabled === false ? '<span class="tag tag-off">Off</span>' : ''}</span>
      <span class="hint">${escapeHtml(ruleSummary(rule))}</span>`;
    text.addEventListener('click', () => { S.openRule = index; renderRules(); });
    card.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      popMenu(e.clientX, e.clientY, [
        ['edit', 'Edit', () => { S.openRule = index; renderRules(); }],
        ['copy', 'Duplicate', () => duplicateRule(index)],
        null,
        ['trash', 'Delete', () => removeRule(index), true],
      ]);
    });
    head.append(text);
  }
  head.append(mkBtn('chevron', open ? 'Fold' : 'Edit', () => {
    S.openRule = open ? -1 : index;
    renderRules();
  }, 'btn btn-icon btn-sm rule-chev'));
  card.append(head);
  if (!open) return card;

  const body = document.createElement('div');
  body.className = 'rule-body';
  card.append(body);
  if (S.ruleJson) body.append(ruleJsonEditor(rule, index));
  else body.append(ruleSentence(rule), ruleExtras(rule));

  const desc = document.createElement('input');
  desc.className = 'rule-desc';
  desc.placeholder = 'A note on what this action is for (optional)';
  desc.value = rule.description || '';
  desc.addEventListener('input', () => { rule.description = desc.value; rulesChanged(); });
  if (!S.ruleJson) body.append(desc);

  const fired = S.triggers.filter((t) => t.rule === rule.name).slice(0, 5);
  const log = document.createElement('div');
  log.className = 'rule-log';
  log.innerHTML = `<span class="label">This action's recent triggers</span>${fired.length
    ? fired.map((t) => `<div class="trig"><time>${fmtTime(t.ts)}</time><span>${escapeHtml(triggerText(t))}</span></div>`).join('')
    : '<span class="hint">Not fired yet.</span>'}`;
  body.append(log);
  return card;
}

// One inline value inside the sentence: a small input that edits a path.
function token(rule, path, kind, placeholder) {
  if (kind === 'speed') {
    const field = unitInput('speed', getPath(rule, path) ?? null, () => {
      const value = field.read();
      setPath(rule, path, value === '' || !Number.isFinite(Number(value)) ? value : Number(value));
      rulesChanged();
    }, placeholder);
    field.el.classList.add('tok');
    return field.el;
  }
  const input = document.createElement('input');
  input.className = `tok${kind === 'text' ? ' tok-text' : ''}`;
  if (kind === 'number') { input.type = 'number'; input.min = '0'; input.step = 'any'; }
  input.placeholder = placeholder || '';
  input.value = getPath(rule, path) ?? '';
  input.setAttribute('aria-label', placeholder || path);
  input.addEventListener('input', () => {
    const text = input.value.trim();
    setPath(rule, path, text === '' ? '' : kind === 'number' ? Number(text) : text);
    rulesChanged();
  });
  return input;
}

function tokSelect(choices, value, onPick, label) {
  const select = document.createElement('select');
  select.className = 'tok tok-select';
  select.setAttribute('aria-label', label);
  select.innerHTML = choices.map(([v, words]) => `<option value="${escapeHtml(v)}">${escapeHtml(words)}</option>`).join('');
  select.value = value;
  select.addEventListener('change', () => { fitSelect(select); onPick(select.value); });
  requestAnimationFrame(() => fitSelect(select));
  return select;
}

/* A select is as wide as its longest option; in a sentence it should be as
   wide as the words it shows. */
const fitCanvas = document.createElement('canvas').getContext('2d');
function fitSelect(select) {
  const style = getComputedStyle(select);
  fitCanvas.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  const text = select.selectedOptions[0]?.text || '';
  const pad = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
  select.style.width = `${Math.ceil(fitCanvas.measureText(text).width + pad + 4)}px`;
}

function ruleSentence(rule) {
  const when = rule.when ??= {};
  const p = document.createElement('p');
  p.className = 'rule-sentence';
  const words = (text) => p.append(document.createTextNode(text));

  const statuses = when.statuses || ['active'];
  const key = statuses.join('+');
  const choices = STATUS_CHOICES.map(([list, w]) => [list.join('+'), w]);
  if (!choices.some(([v]) => v === key)) choices.push([key, `a ${statuses.map(statusLabel).join(' or ').toLowerCase()}`]);
  words('When ');
  p.append(tokSelect(choices, key, (v) => { when.statuses = v.split('+'); rulesChanged(); }, 'Which downloads'));
  words(' download ');
  const kind = when.torrent_only ? 'torrent' : when.http_only ? 'http' : 'any';
  p.append(tokSelect(KIND_CHOICES, kind, (v) => {
    setPath(rule, 'when.torrent_only', v === 'torrent' ? true : '');
    setPath(rule, 'when.http_only', v === 'http' ? true : '');
    rulesChanged();
  }, 'What kind'));
  words(' stays ');
  const above = blank(when.speed_below) && !blank(when.speed_above);
  const speedPath = above ? 'when.speed_above' : 'when.speed_below';
  p.append(tokSelect([['below', 'below'], ['above', 'above']], above ? 'above' : 'below', (v) => {
    const value = getPath(rule, speedPath);
    setPath(rule, speedPath, '');
    setPath(rule, v === 'above' ? 'when.speed_above' : 'when.speed_below', value);
    renderRules();
  }, 'Below or above'));
  words(' ');
  p.append(token(rule, speedPath, 'speed', 'any speed'));
  words(' for ');
  p.append(token(rule, 'when.for_seconds', 'number', '0'));
  words(' s, ');
  const action = rule.action || 'pause_resume';
  p.append(tokSelect(Object.entries(ACTION_WORDS), action, (v) => { rule.action = v; renderRules(); }, 'What it does'));
  if (RESUMES.has(action)) {
    words(' after ');
    p.append(token(rule, 'resume_after_seconds', 'number', '1.5'));
    words(' s');
  }
  words('.');
  if (action === 'set_option') {
    const hint = document.createElement('span');
    hint.className = 'hint rule-note';
    const opts = Object.entries(rule.options || {}).map(([k, v]) => `${k} = ${v}`).join(', ');
    hint.textContent = opts
      ? `Sets ${opts}. Edit the options as JSON ({} above).`
      : 'Which options it changes is set as JSON ({} above), under "options".';
    p.append(hint);
  }
  return p;
}

function ruleExtras(rule) {
  const row = document.createElement('div');
  row.className = 'chiprow rule-extras';
  const unused = [];
  for (const [path, before, after, start, kind] of RULE_EXTRAS) {
    if (blank(getPath(rule, path))) { unused.push([path, before, after, start]); continue; }
    const chip = document.createElement('span');
    chip.className = 'chip rule-cond';
    chip.append(document.createTextNode(`${before} `), token(rule, path, kind, String(start)));
    if (after) chip.append(document.createTextNode(after === '%' ? '%' : ` ${after}`));
    const x = document.createElement('button');
    x.type = 'button';
    x.className = 'x';
    x.setAttribute('aria-label', `Remove "${before}"`);
    x.textContent = '×';
    x.addEventListener('click', () => { setPath(rule, path, ''); renderRules(); });
    chip.append(x);
    row.append(chip);
  }
  if (unused.length) {
    const add = document.createElement('select');
    add.className = 'chip rule-add-cond';
    add.setAttribute('aria-label', 'Add a condition');
    add.innerHTML = `<option value="">+ Condition</option>${unused
      .map(([path, before, after]) => `<option value="${path}">${escapeHtml(`${before} …${after ? ` ${after}` : ''}`)}</option>`).join('')}`;
    requestAnimationFrame(() => fitSelect(add));
    add.addEventListener('change', () => {
      const pick = unused.find(([path]) => path === add.value);
      if (!pick) return;
      setPath(rule, pick[0], pick[3]);
      renderRules();
    });
    row.append(add);
  }
  return row;
}

function ruleJsonEditor(rule, index) {
  const wrap = document.createElement('div');
  wrap.className = 'rule-json';
  const area = document.createElement('textarea');
  area.rows = 14;
  area.spellcheck = false;
  area.value = JSON.stringify(rule, null, 2);
  const problem = document.createElement('span');
  problem.className = 'hint err';
  area.addEventListener('input', () => {
    try {
      S.rules[index] = JSON.parse(area.value);
      problem.textContent = '';
      rulesChanged();
    } catch (err) {
      problem.textContent = `Not valid JSON yet: ${err.message}`;
    }
  });
  wrap.append(area, problem);
  return wrap;
}

/* ------------------------------------------------------------------- log */
function renderLog() {
  const show = S.logShow || 'all';
  const counts = { all: S.events.length, error: 0, rule: 0 };
  for (const e of S.events) if (e.level in counts) counts[e.level] += 1;
  for (const chip of $$('#log-filter [data-show]')) {
    chip.classList.toggle('active', chip.dataset.show === show);
    $('.n', chip).textContent = counts[chip.dataset.show] || '';
  }
  const shown = show === 'all' ? S.events : S.events.filter((e) => e.level === show);
  $('#loglist').innerHTML = shown.map((e) => `
    <div class="logline ${e.level}">
      <time>${fmtTime(e.ts)}</time><span class="lvl">${e.level}</span>
      <span class="msg">${escapeHtml(e.message)}</span>
    </div>`).join('') || `<p class="hint">${show === 'all' ? 'Nothing logged yet.' : 'Nothing of this kind logged.'}</p>`;
  if ($('#tab-settings').classList.contains('active')) buildToc();
  if (S.events.some((e) => e.level === 'rule')) {
    S.triggers = S.events.filter((e) => e.level === 'rule').map((e) => ({
      ts: e.ts, rule: e.rule || '?', action: e.action || '', name: e.message, speed: e.speed || 0, detail: '', logLine: true,
    }));
    // A fresh trigger shows under its action, unless that would pull the
    // field being typed in out from under the cursor.
    if ($('#tab-rules').classList.contains('active') && !$('#rules-list').contains(document.activeElement)) renderRules();
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
//: One filter, whichever control picked it: a rail entry or a narrow-window chip.
function setFilter(filter) {
  S.filter = filter;
  $$('[data-filter]').forEach((c) => c.classList.toggle('active', c.dataset.filter === filter));
  for (const [, row] of S.rows) row.remove();
  S.rows.clear();
  $('#downloads').innerHTML = '';
  S.selection.clear();
  renderBulkBar();
  renderSortControl();
  if (S.filter === 'history') loadHistory();
  else { $('#history-bar').hidden = true; renderDownloads(); }
}

function switchTab(name) {
  $$('.tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
  $$('.rail [data-tab]').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
  $$('.rail [data-filter]').forEach((t) => t.classList.toggle('active', name === 'downloads' && t.dataset.filter === S.filter));
  document.body.dataset.tab = name;
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

  $$('.tab, .rail [data-tab]').forEach((tab) => tab.addEventListener('click', () => switchTab(tab.dataset.tab)));
  $$('[data-filter]').forEach((chip) => chip.addEventListener('click', () => {
    switchTab('downloads');
    setFilter(chip.dataset.filter);
  }));
  $('#btn-add-rail').addEventListener('click', openAdd);
  $('#pane-close').addEventListener('click', () => { if (S.paneGid) toggleDetail(S.paneGid); });
  // Crossing the wide/narrow line moves the details between pane and row.
  WIDE.addEventListener('change', () => {
    if (S.paneGid && !WIDE.matches) { const gid = S.paneGid; S.paneGid = ''; renderPane(); toggleDetail(gid); }
    for (const gid of [...S.expanded]) if (WIDE.matches) { toggleDetail(gid); toggleDetail(gid); }
  });
  $('#trouble-retry').addEventListener('click', () => {
    api('/api/state').then(applyState).catch((err) => toast(err.message, 'error'));
  });
  $('#trouble-copy').addEventListener('click', () => {
    navigator.clipboard.writeText($('#trouble-cmd').textContent).then(() => toast('Copied', 'ok'), () => {});
  });
  $('#banner-restart').addEventListener('click', () => post('/api/aria2/restart', null, 'aria2c restarted'));
  $('#banner-log').addEventListener('click', () => revealLog());
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

  $('#btn-flip').addEventListener('click', (e) => {
    const pause = e.currentTarget.dataset.mode === 'pause';
    post(pause ? '/api/global/pause-all' : '/api/global/resume-all', null,
      pause ? 'Paused everything' : 'Resumed everything');
  });
  $('#btn-purge').addEventListener('click', () => act('/api/global/purge', { method: 'POST' }, 'Cleared finished and failed'));

  $('#btn-opt-reload').addEventListener('click', loadGlobalOptions);
  $('#btn-opt-save').addEventListener('click', saveGlobalOptions);
  $('#opt-search').addEventListener('input', applyOptionFilter);
  $('#btn-restart-aria2').addEventListener('click', async () => {
    if (!confirm('Restart aria2c? Active downloads pause and pick up again from the session file.')) return;
    await act('/api/aria2/restart', { method: 'POST' }, 'aria2c restarted');
  });

  for (const btn of document.querySelectorAll('#rules-measure [data-source]')) {
    btn.addEventListener('click', async () => {
      S.speedSource = btn.dataset.source;
      paintMeasure();
      await act('/api/rules', { method: 'POST', body: { speed_source: S.speedSource } },
        `Speed measured by ${btn.textContent.trim()}`);
    });
  }
  $('#btn-rule-add').addEventListener('click', () => addRule());
  $('#btn-rules-save').addEventListener('click', saveRules);
  $('#btn-rules-discard').addEventListener('click', discardRules);
  $('#rules-master').addEventListener('change', async (e) => {
    await act('/api/rules', { method: 'POST', body: { enabled: e.target.checked } },
      e.target.checked ? 'Actions on' : 'Actions off');
  });
  $('#btn-log-clear').addEventListener('click', () => { S.events = []; renderLog(); });
  for (const chip of $$('#log-filter [data-show]')) {
    chip.addEventListener('click', () => { S.logShow = chip.dataset.show; renderLog(); });
  }
  $('#btn-log-copy').addEventListener('click', () => {
    const text = S.events.map((e) => `${fmtDate(e.ts)}  ${e.level.toUpperCase().padEnd(5)}  ${e.message}`).join('\n');
    navigator.clipboard.writeText(text).then(() => toast('Log copied', 'ok'), (err) => toast(err.message, 'error'));
  });
  $('#btn-opt-discard').addEventListener('click', discardSettings);
  // Every edit in the settings tab updates the save bar.
  $('#tab-settings').addEventListener('input', settingsChanged);
  $('#tab-settings').addEventListener('change', settingsChanged);
  window.addEventListener('scroll', () => { if (document.body.dataset.tab === 'settings') spyToc(); }, { passive: true });

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

  // Opening the manager is looking: the toolbar icon's finished-download dot goes.
  const ext = globalThis.browser || globalThis.chrome;
  ext?.runtime?.sendMessage?.({ type: 'seen' })?.catch?.(() => {});

  // The popup's "Open log" lands here with #log.
  if (location.hash === '#log') revealLog();
  else if (location.hash === '#rules' || location.hash === '#settings') switchTab(location.hash.slice(1));
  else switchTab('downloads');

  connect();
}

//: Settings, Advanced, scrolled to the event log.
function revealLog() {
  switchTab('settings');
  if (S.settingsMode !== 'advanced') setSettingsMode('advanced');
  requestAnimationFrame(() => $('#loglist')?.scrollIntoView({ behavior: 'smooth', block: 'center' }));
}

document.addEventListener('DOMContentLoaded', init);
