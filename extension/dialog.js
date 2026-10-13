/* The download dialog: opened by the background for each caught download while
   "Show a download dialog" is on.

   A plain file gets what IDM asks: name, folder, size, connections, speed.
   Nothing is queued until Download is pressed.

   A torrent gets what qBittorrent asks: it is added held (a magnet fetches its
   file list and waits; a .torrent waits stopped), then the dialog shows the
   files with their priorities and the torrent's options. Download applies them
   and starts it; Cancel, or closing the window, removes it again.

   Only the extension opens this. The manager never asks for it, so the DankBar
   widget, which talks to the same manager, never shows a second one. */
'use strict';

const $ = (id) => document.getElementById(id);
const store = api.storage.session || api.storage.local;

const LEVELS = [[0, 'Do not download'], [1, 'Normal'], [2, 'High'], [3, 'Maximum']];
const RECENT_DIRS = 8;

const D = {
  payload: null,
  kind: 'file',
  probe: null,
  defaultDir: '',
  // Torrent state
  gid: '',
  owned: new Set(),   // gids this dialog added, removed again if it is closed
  engine: '',
  files: [],
  levels: {},
  base: '',
  dirAtLoad: '',
  settled: false,
};

async function call(method, path, body) {
  const reply = await ManagerLink.call(method, path, body);
  if (reply.status < 200 || reply.status >= 300) throw new Error(ManagerLink.errorText(reply));
  return reply.body;
}

function showError(message) {
  $('error').textContent = message;
  $('error').hidden = !message;
}

function busy(text) {
  $('body').innerHTML = `<p class="loading"><span class="spinner" aria-hidden="true"></span><span id="loading-text"></span></p>`;
  $('loading-text').textContent = text;
}

function notice(text) {
  $('body').innerHTML = '<p class="notice"></p>';
  $('body').firstElementChild.textContent = text;
}

function mount(templateId) {
  $('body').replaceChildren($(templateId).content.cloneNode(true));
}

async function recentDirs() {
  const { recentDirs: dirs = [] } = await api.storage.local.get({ recentDirs: [] });
  $('recent-dirs').replaceChildren(...dirs.map((d) => Object.assign(document.createElement('option'), { value: d })));
}

async function rememberDir(dir) {
  if (!dir) return;
  const { recentDirs: dirs = [] } = await api.storage.local.get({ recentDirs: [] });
  await api.storage.local.set({ recentDirs: [dir, ...dirs.filter((d) => d !== dir)].slice(0, RECENT_DIRS) });
}

function closeSoon() {
  D.settled = true;
  window.close();
}

/* ------------------------------------------------------------------ start */
async function init() {
  const id = location.hash.slice(1);
  const key = `dialog:${id}`;
  const stored = await store.get(key);
  D.payload = stored[key];
  if (!D.payload) {
    $('title').textContent = 'Nothing to download';
    $('subtitle').textContent = '';
    notice('This dialog has expired. Start the download again from the page.');
    return;
  }
  store.remove(key);
  const p = D.payload;
  $('btn-browser').hidden = !/^https?:/i.test(p.url);
  $('title').textContent = p.filename || filenameFromUrl(p.url) || 'New download';
  $('subtitle').textContent = p.url;
  recentDirs();

  try {
    const ping = await call('GET', '/api/intake/ping');
    D.defaultDir = ping.defaultDir || '';
  } catch (err) {
    notice(`The manager is not answering: ${err.message}`);
    return;
  }

  let torrent = /^magnet:/i.test(p.url) || isTorrentFile(p.url, p.filename, p.mime);
  if (!torrent) {
    busy('Checking the link…');
    try {
      D.probe = await call('POST', '/api/intake/probe', {
        url: p.url, referer: p.referer || null, cookie: p.cookie || null, userAgent: p.userAgent || null,
      });
      torrent = D.probe.kind === 'torrent';
    } catch {
      D.probe = null;
    }
  }
  if (torrent) await startTorrent();
  else await showFile();
}

/* ------------------------------------------------------------ plain file */
async function showFile() {
  D.kind = 'file';
  const p = D.payload;
  const probe = D.probe || {};
  mount('file-view');
  $('f-url').value = p.url;
  $('f-name').value = p.filename || probe.name || filenameFromUrl(p.url);
  $('f-dir').value = p.dir || '';
  $('f-dir').placeholder = D.defaultDir || 'Download folder';
  const size = p.size || probe.size;
  $('f-size').textContent = size ? humanBytes(size) : 'Unknown';
  $('f-type').textContent = (probe.contentType || p.mime || '—').split(';')[0] || '—';
  $('f-resume').textContent = probe.resumable == null ? '—' : probe.resumable ? 'Yes' : 'No';
  if (probe.error) $('f-resume').title = probe.error;
  try {
    const global = await call('GET', '/api/global/options');
    $('f-conn').placeholder = global['max-connection-per-server'] || '';
    $('f-split').placeholder = global.split || '';
  } catch { /* placeholders are a nicety */ }
  $('title').textContent = $('f-name').value || 'New download';
  $('f-name').addEventListener('input', () => { $('title').textContent = $('f-name').value || 'New download'; });
  $('btn-start').disabled = false;
  $('btn-later').disabled = false;
  $('f-name').focus();
  $('f-name').select();
}

async function submitFile(later) {
  const p = D.payload;
  const options = {};
  if ($('f-conn').value.trim()) options['max-connection-per-server'] = $('f-conn').value.trim();
  if ($('f-split').value.trim()) options.split = $('f-split').value.trim();
  if ($('f-limit').value.trim()) options['max-download-limit'] = `${$('f-limit').value.trim()}${$('f-limit-unit').value}`;
  const dir = $('f-dir').value.trim();
  const name = $('f-name').value.trim();
  await call('POST', '/api/intake/add', {
    url: p.url,
    filename: name || null,
    referer: p.referer || null,
    cookie: p.cookie || null,
    userAgent: p.userAgent || null,
    dir: dir || null,
    paused: later || !!p.paused,
    source: p.source || null,
    options,
  });
  await rememberDir(dir);
  await api.runtime.sendMessage({ type: 'dialogAdded', name: name || p.url }).catch(() => {});
  closeSoon();
}

/* --------------------------------------------------------------- torrent */
async function startTorrent() {
  D.kind = 'torrent';
  const p = D.payload;
  $('btn-later').hidden = true;
  busy(/^magnet:/i.test(p.url) ? 'Getting the file list from peers…' : 'Reading the torrent…');
  let added;
  try {
    added = await call('POST', '/api/intake/add', {
      url: p.url,
      filename: p.filename || null,
      referer: p.referer || null,
      cookie: p.cookie || null,
      userAgent: p.userAgent || null,
      dir: p.dir || null,
      source: p.source || null,
      options: { 'pause-metadata': 'true' },
    });
  } catch (err) {
    notice(`Could not add the torrent: ${err.message}`);
    return;
  }
  D.gid = (added.gids || [])[0] || '';
  if ((added.existing || []).includes(D.gid)) {
    D.settled = true;
    notice('This torrent is already in your downloads. Change its files from the manager.');
    $('btn-cancel').textContent = 'Close';
    return;
  }
  D.owned.add(D.gid);
  const started = Date.now();
  let misses = 0;
  while (!D.settled) {
    let data = null;
    try {
      data = await call('GET', `/api/download/${D.gid}`);
      misses = 0;
    } catch (err) {
      // A just-added torrent can take a moment to be listed.
      if (++misses > 10) { notice(`Lost the torrent: ${err.message}`); return; }
    }
    const st = (data && data.status) || {};
    const next = (st.followedBy || [])[0];
    if (next) {
      // aria2: the magnet's metadata download became the real torrent.
      D.gid = next;
      D.owned.add(next);
      continue;
    }
    if (data && isReady(data)) { showTorrent(data); return; }
    if (st.status === 'error') { notice(`The torrent failed: ${st.errorMessage || 'unknown error'}`); return; }
    const secs = Math.round((Date.now() - started) / 1000);
    const peers = Number(st.connections || 0);
    $('loading-text').textContent = `Getting the file list from peers… ${secs}s`
      + (peers ? ` · ${peers} connected` : '');
    await new Promise((r) => setTimeout(r, 1000));
  }
}

function isReady(data) {
  const files = data.files || [];
  if (!files.length) return false;
  if (String(files[0].path || '').startsWith('[METADATA]')) return false;
  return !/^(forced)?metaDL$/i.test((data.status || {}).qbState || '');
}

function relative(path) {
  return D.base && path.startsWith(`${D.base}/`) ? path.slice(D.base.length + 1) : path;
}

function showTorrent(data) {
  const st = data.status || {};
  D.engine = data.engine || 'aria2';
  D.files = data.files || [];
  D.base = st.dir || '';
  D.dirAtLoad = st.dir || '';
  D.levels = Object.fromEntries(D.files.map((f) => [f.index, f.priority ?? (f.selected === 'true' ? 1 : 0)]));
  const name = ((st.bittorrent || {}).info || {}).name || D.payload.filename || 'Torrent';
  $('title').textContent = name;
  $('subtitle').textContent = /^magnet:/i.test(D.payload.url) ? 'Magnet link' : D.payload.url;

  mount('torrent-view');
  const qb = D.engine === 'qbittorrent';
  for (const el of document.querySelectorAll('[data-qb]')) el.hidden = !qb;
  $('t-engine').textContent = qb ? 'qBittorrent' : 'aria2c';
  $('t-dir').value = D.payload.dir || st.dir || '';
  $('t-dir').placeholder = D.defaultDir || 'Download folder';
  const opts = data.options || {};
  $('t-seq').checked = opts['sequential-download'] === 'true';
  $('t-fl').checked = opts['first-last-piece-first'] === 'true';
  call('GET', '/api/state').then((state) => {
    const everywhere = Boolean(state.torrent && state.torrent.downloadOnly);
    $('t-donly').checked = everywhere || opts['download-only'] === 'true';
    $('t-donly').disabled = everywhere;
    $('t-donly-hint').textContent = everywhere ? 'On for every torrent in Settings' : '';
  }).catch(() => {});

  for (const [value, label] of LEVELS) {
    $('t-setall').append(Object.assign(document.createElement('option'), { value, textContent: label }));
  }
  $('t-filter').hidden = D.files.length < 15;
  renderFiles();

  $('t-all').addEventListener('change', (e) => {
    for (const f of visibleFiles()) D.levels[f.index] = e.target.checked ? Math.max(1, D.levels[f.index]) || 1 : 0;
    renderFiles();
  });
  $('t-setall').addEventListener('change', (e) => {
    if (e.target.value === '') return;
    for (const f of visibleFiles()) D.levels[f.index] = Number(e.target.value);
    e.target.value = '';
    renderFiles();
  });
  $('t-filter').addEventListener('input', renderFiles);
  $('btn-start').disabled = false;
}

function visibleFiles() {
  const needle = ($('t-filter').value || '').trim().toLowerCase();
  return needle ? D.files.filter((f) => relative(f.path).toLowerCase().includes(needle)) : D.files;
}

function renderFiles() {
  const rows = visibleFiles().map((f) => {
    const level = D.levels[f.index];
    const rel = relative(f.path);
    const cut = rel.lastIndexOf('/');
    const row = document.createElement('div');
    row.className = `tfile${level === 0 ? ' is-skipped' : ''}`;
    row.setAttribute('role', 'listitem');
    row.innerHTML = `
      <input type="checkbox" aria-label="Download this file"${level > 0 ? ' checked' : ''}>
      <span class="fname" title=""><span class="fdir"></span><span class="fbase"></span></span>
      <span class="fsize">${humanBytes(Number(f.length))}</span>
      <select aria-label="Priority">${LEVELS.map(([v, label]) =>
        `<option value="${v}"${v === level ? ' selected' : ''}>${label}</option>`).join('')}</select>`;
    row.querySelector('.fname').title = rel;
    row.querySelector('.fdir').textContent = cut >= 0 ? rel.slice(0, cut + 1) : '';
    row.querySelector('.fbase').textContent = cut >= 0 ? rel.slice(cut + 1) : rel;
    // One file's change updates its own row only, so focus stays put.
    const box = row.querySelector('input');
    const pick = row.querySelector('select');
    const set = (value) => {
      D.levels[f.index] = value;
      box.checked = value > 0;
      pick.value = String(value);
      row.classList.toggle('is-skipped', value === 0);
      updateTotals();
    };
    box.addEventListener('change', () => set(box.checked ? 1 : 0));
    pick.addEventListener('change', () => set(Number(pick.value)));
    return row;
  });
  $('t-files').replaceChildren(...rows);
  updateTotals();
}

function updateTotals() {
  const total = D.files.reduce((n, f) => n + Number(f.length), 0);
  const chosen = D.files.filter((f) => D.levels[f.index] > 0);
  const selected = chosen.reduce((n, f) => n + Number(f.length), 0);
  $('t-total').textContent = humanBytes(total);
  $('t-selected').textContent = humanBytes(selected);
  $('t-count').textContent = `${chosen.length} of ${D.files.length}`;
  const visible = visibleFiles();
  const on = visible.filter((f) => D.levels[f.index] > 0).length;
  $('t-all').checked = on === visible.length && on > 0;
  $('t-all').indeterminate = on > 0 && on < visible.length;
  $('btn-start').disabled = chosen.length === 0;
}

async function submitTorrent() {
  const gid = D.gid;
  await call('POST', `/api/download/${gid}/files`, { levels: D.levels });
  const options = {};
  const dir = $('t-dir').value.trim();
  if (dir && dir !== D.dirAtLoad) options.dir = dir;
  if (!$('t-donly').disabled) options['download-only'] = String($('t-donly').checked);
  if (D.engine === 'qbittorrent') {
    options['sequential-download'] = String($('t-seq').checked);
    options['first-last-piece-first'] = String($('t-fl').checked);
  }
  if (Object.keys(options).length) {
    await call('POST', `/api/download/${gid}/options`, { options });
  }
  if (!D.payload.paused) await call('POST', `/api/download/${gid}/resume`);
  await rememberDir(dir);
  // The metadata download (aria2) has done its job; the torrent is the user's now.
  D.owned.clear();
  await api.runtime.sendMessage({ type: 'dialogAdded', name: $('title').textContent }).catch(() => {});
  closeSoon();
}

/* ---------------------------------------------------------------- buttons */
async function guarded(button, work) {
  button.disabled = true;
  showError('');
  try {
    await work();
  } catch (err) {
    showError(err.message);
    button.disabled = false;
  }
}

$('btn-start').addEventListener('click', (e) => guarded(e.currentTarget,
  () => (D.kind === 'torrent' ? submitTorrent() : submitFile(false))));
$('btn-later').addEventListener('click', (e) => guarded(e.currentTarget, () => submitFile(true)));
$('btn-cancel').addEventListener('click', () => {
  abandon();
  closeSoon();
});
$('btn-browser').addEventListener('click', (e) => guarded(e.currentTarget, async () => {
  abandon();
  const reply = await api.runtime.sendMessage({ type: 'dialogBrowser', url: D.payload.url });
  if (!reply || !reply.ok) throw new Error((reply && reply.error) || 'the browser would not start it');
  closeSoon();
}));
$('keep-asking').addEventListener('change', (e) => {
  saveSettings({ askBeforeDownload: e.target.checked });
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') $('btn-cancel').click();
  if (e.key === 'Enter' && e.target.tagName === 'INPUT' && e.target.type !== 'checkbox'
      && !$('btn-start').disabled) $('btn-start').click();
});

// A torrent added only to read its file list goes again if nothing was chosen.
function abandon() {
  if (!D.owned.size) return;
  const gids = [...D.owned];
  D.owned.clear();
  api.runtime.sendMessage({ type: 'dialogAbandon', gids }).catch(() => {});
}
window.addEventListener('pagehide', () => { if (!D.settled) abandon(); });

init().catch((err) => notice(err.message));
