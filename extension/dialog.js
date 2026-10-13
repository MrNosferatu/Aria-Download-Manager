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

/* ------------------------------------------------------------- folders */
/* "Save to" is a menu of the folders that already mean something: the download
   folder (or, with sorting on, the folder this file sorts into), each sorting
   folder, and the recent ones. "Choose…" opens the desktop's folder chooser
   through the manager; without one installed, a path can be typed instead. */
const home = (path) => path.replace(/^\/home\/[^/]+|^\/root(?=\/|$)/, '~');

function option(value, label, title) {
  return Object.assign(document.createElement('option'), { value, textContent: label, title: title || value });
}

async function setupFolder(pre, name, initial) {
  const sel = $(`${pre}-dir`);
  let info = { base: D.defaultDir, presets: [], sorting: false, suggested: '', picker: false };
  try {
    info = await call('GET', `/api/folders?name=${encodeURIComponent(name || '')}`);
  } catch {
    showError('The manager did not list its folders. Restart it to get the folder presets.');
  }
  const { recentDirs: recent = [] } = await api.storage.local.get({ recentDirs: [] });

  // "" is the manager's download folder. The preset folders follow, and the
  // one for this file's type (a .zip: Archives) is chosen to start with.
  const base = option('', `Downloads · ${home(info.base || 'download folder')}`, info.base);
  // One flat list: the presets, then recent folders.
  const known = new Set(['', info.base]);
  const items = [base];
  for (const preset of info.presets || []) {
    if (known.has(preset.path)) continue;
    known.add(preset.path);
    items.push(option(preset.path, `${preset.label} · ${home(preset.path)}`));
  }
  for (const dir of [initial, ...recent]) {
    if (!dir || known.has(dir)) continue;
    known.add(dir);
    items.push(option(dir, home(dir)));
  }
  sel.replaceChildren(...items);
  const start = initial || (info.suggested && info.suggested !== info.base ? info.suggested : '');
  sel.value = start;
  if (sel.value !== start) sel.value = '';

  $(`${pre}-browse`).addEventListener('click', async (e) => {
    const button = e.currentTarget;
    button.disabled = true;
    showError('');
    try {
      const picked = await call('POST', '/api/pick-folder', { start: folderOf(pre) || info.base });
      if (picked.path) {
        if (![...sel.options].some((o) => o.value === picked.path)) {
          sel.append(option(picked.path, home(picked.path)));
        }
        sel.value = picked.path;
        $(`${pre}-dir-custom`).hidden = true;
      }
    } catch (err) {
      // No chooser on this desktop: type it instead.
      const custom = $(`${pre}-dir-custom`);
      custom.hidden = false;
      custom.focus();
      showError(/no folder picker/i.test(err.message)
        ? 'No folder chooser is installed (zenity, kdialog or yad). Type the folder instead.' : err.message);
    } finally {
      button.disabled = false;
    }
  });
}

// The folder chosen in a "Save to" menu ("" = the manager decides).
function folderOf(pre) {
  const custom = $(`${pre}-dir-custom`);
  return (custom && !custom.hidden && custom.value.trim()) || $(`${pre}-dir`).value;
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
  // A tiling compositor (niri, Hyprland) would tile this window; the manager
  // asks it to float it instead. Fire and forget: it waits for the window.
  ManagerLink.call('POST', '/api/window/float', {
    title: document.title, width: window.outerWidth, height: window.outerHeight,
  }).catch(() => {});
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
  $('f-name').value = (p.nameGuessed ? probe.name || p.filename : p.filename || probe.name)
    || filenameFromUrl(p.url);
  setupFolder('f', $('f-name').value, p.dir || '');
  if (pageInsteadOfFile($('f-name').value, p.mime, probe)) {
    // The manager would only save that page: steer to the browser.
    $('f-page').hidden = false;
    $('btn-browser').className = 'btn btn-primary';
    $('btn-start').className = 'btn btn-outline';
    $('btn-later').hidden = true;
  }
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
  const dir = folderOf('f').trim();
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
  dropBrowser();
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
  // What the torrent mostly is: its biggest file decides the folder.
  const biggest = D.files.reduce((a, f) => (Number(f.length) > Number(a.length) ? f : a), D.files[0]);
  setupFolder('t', biggest ? relative(biggest.path) : name, D.payload.dir || '');
  const opts = data.options || {};
  $('t-seq').checked = opts['sequential-download'] === 'true';
  $('t-fl').checked = opts['first-last-piece-first'] === 'true';
  $('t-donly').checked = opts['download-only'] === 'true';
  call('GET', '/api/state').then((state) => {
    if (!(state.torrent && state.torrent.downloadOnly)) return;
    // Settings decides for every torrent: say so rather than offer a switch.
    $('t-donly').checked = true;
    $('t-donly').disabled = true;
    $('t-donly-hint').textContent = 'On for every torrent (Settings).';
  }).catch(() => {});

  // The files as a tree, like qBittorrent's: nothing has downloaded yet, so
  // no progress column.
  mountFileTree($('t-tree'), {
    files: D.files,
    base: D.base,
    levels: D.levels,
    progress: false,
    onChange: (levels) => {
      D.levels = levels;
      $('btn-start').disabled = !Object.values(levels).some((v) => Number(v) > 0);
    },
  });
  $('btn-start').disabled = !Object.values(D.levels).some((v) => Number(v) > 0);
}

async function submitTorrent() {
  const gid = D.gid;
  await call('POST', `/api/download/${gid}/files`, { levels: D.levels });
  const options = {};
  const dir = folderOf('t').trim();
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
  dropBrowser();
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
  dropBrowser();
  closeSoon();
});
$('btn-browser').addEventListener('click', (e) => guarded(e.currentTarget, async () => {
  abandon();
  const browserId = D.payload.browserId;
  D.payload.browserId = null;  // resumed below, not dropped
  const reply = await api.runtime.sendMessage({ type: 'dialogBrowser', url: D.payload.url, browserId });
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
// The browser's own download, held paused while this window decides, goes once
// the manager has the file or the user said no.
function dropBrowser() {
  const browserId = D.payload && D.payload.browserId;
  if (browserId === null || browserId === undefined) return;
  D.payload.browserId = null;
  api.runtime.sendMessage({ type: 'dialogDropBrowser', browserId }).catch(() => {});
}
window.addEventListener('pagehide', () => {
  if (D.settled) return;
  abandon();
  dropBrowser();
});

init().catch((err) => notice(err.message));
