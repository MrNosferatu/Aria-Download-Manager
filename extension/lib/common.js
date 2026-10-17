/* Shared helpers for every extension surface: background, content script,
   popup and options. Loaded as a classic script (no modules) so the same file
   works in a Chrome service worker and a Firefox event page. */
'use strict';

// Firefox exposes `browser`, Chrome only `chrome`. Both speak promises for the
// APIs used here (Chrome since MV3).
const api = globalThis.browser || globalThis.chrome;

const DEFAULTS = {
  // Master switch. Off means the extension touches nothing: the browser keeps
  // its own downloads, no click is captured, no video button appears. It stays
  // installed and the popup still works, it just stops intervening.
  enabled: true,
  // Hand the browser's own downloads to aria2c instead of downloading them here.
  intercept: true,
  // Auto-capture left-clicks on links that look like downloads.
  capture: true,
  // Torrents: magnet: links and .torrent files. Independent of `capture` and
  // `intercept`, so torrents can go to aria2c (or stay with a torrent client)
  // whatever the other switches say. Key name kept for stored settings.
  captureMagnets: true,
  // Alt+click sends any link, even when capture is off.
  altClick: true,
  dir: '',
  paused: false,
  // Open a dialog for each caught download (name, folder, connections; a
  // torrent's files and priorities) instead of queueing it straight away.
  askBeforeDownload: false,
  notify: true,
  // In-page toasts (as well as the OS notifications the browser shows).
  pageToasts: true,
  // Skip files smaller than this (MiB). 0 disables the check.
  minSizeMB: 0,
  // Watch tab traffic for video manifests and offer a download button over the
  // player. This is the only feature that looks at requests rather than clicks.
  videoSniffer: true,
  // Don't offer a button over a thumbnail-sized or decorative player.
  videoMinPx: 200,
  extensions: [
    '7z', 'apk', 'appimage', 'avi', 'bin', 'bz2', 'deb', 'dmg', 'epub', 'exe',
    'flac', 'flv', 'gz', 'img', 'iso', 'm4a', 'm4v', 'mkv', 'mobi', 'mov',
    'mp3', 'mp4', 'msi', 'ogg', 'pdf', 'pkg', 'rar', 'rpm', 'tar', 'tgz',
    'torrent', 'txz', 'wav', 'webm', 'whl', 'xz', 'zip', 'zst',
  ],
  blockedHosts: [],
};

async function loadSettings() {
  const stored = await api.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...stored };
}

async function saveSettings(patch) {
  await api.storage.local.set(patch);
}

// Every call to the manager from the background goes through here. The
// connection itself lives in lib/link.js, shared with the manager page. Short
// timeout on purpose: interception waits on these before touching a download.
async function request(path, payload) {
  const reply = await ManagerLink.call(payload ? 'POST' : 'GET', path, payload,
    { timeout: 15000 });
  if (reply.status < 200 || reply.status >= 300) throw new Error(ManagerLink.errorText(reply));
  return reply.body && typeof reply.body === 'object' ? reply.body : {};
}

function filenameFromUrl(url, downloadAttr) {
  if (downloadAttr && downloadAttr.trim()) return downloadAttr.trim().split('/').pop();
  try {
    const path = new URL(url).pathname;
    return decodeURIComponent(path.split('/').filter(Boolean).pop() || '');
  } catch {
    return '';
  }
}

function hostOf(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

function hostMatches(list, host) {
  // A rule for example.com covers cdn.example.com too — an exclusion the user
  // has to restate for every subdomain is not much of an exclusion.
  return !!host && (list || []).some((h) => host === h || host.endsWith('.' + h));
}

/* A download has two hosts worth checking: where the file comes from, and the
   page that asked for it. Files are routinely served from a CDN on an unrelated
   domain, so excluding "the site I am on" has to match the page as well or it
   quietly does nothing. Either one matching is enough to leave it alone. */
function isBlocked(settings, url, pageUrl) {
  const list = settings.blockedHosts || [];
  if (!list.length) return false;
  return hostMatches(list, hostOf(url)) || hostMatches(list, hostOf(pageUrl || ''));
}

const isMagnet = (url) => /^magnet:/i.test(url || '');

// A .torrent file, judged by URL, file name or MIME type.
function isTorrentFile(url, name, mime) {
  if (/bittorrent/i.test(mime || '')) return true;
  if (/\.torrent$/i.test(name || '')) return true;
  try {
    return /\.torrent$/i.test(new URL(url).pathname);
  } catch {
    return false;
  }
}

// Does this link look like a file rather than a page? Used for click capture;
// browser-initiated downloads skip this, since the browser already decided.
function looksDownloadable(settings, url, hasDownloadAttr, pageUrl) {
  if (isMagnet(url)) return settings.captureMagnets;
  if (!/^https?:\/\//i.test(url)) return false;
  if (isBlocked(settings, url, pageUrl)) return false;
  if (!settings.captureMagnets && isTorrentFile(url)) return false;
  if (hasDownloadAttr) return true;
  try {
    const ext = (new URL(url).pathname.split('.').pop() || '').toLowerCase();
    return settings.extensions.includes(ext);
  } catch {
    return false;
  }
}

// Does this name promise a file rather than a web page? A site that answers
// the manager with a page for such a name will only give the file to the
// browser (a captcha, a login, a link good for one request).
const PAGE_EXTENSIONS = new Set(['html', 'htm', 'xhtml', 'shtml', 'php', 'asp', 'aspx', 'jsp',
  'cgi', 'xml', 'svg', 'txt', 'json']);
function expectsBinary(name) {
  const match = /\.([a-z0-9]+)$/i.exec(name || '');
  return !!match && !PAGE_EXTENSIONS.has(match[1].toLowerCase());
}

function pageInsteadOfFile(name, browserMime, probe) {
  if (probe && probe.page) return !/html/i.test(browserMime || '');
  return !!probe && /text\/html/i.test(probe.contentType || '')
    && expectsBinary(name) && !/html/i.test(browserMime || '');
}

// aria2 cannot fetch these, so they must never be intercepted.
const isFetchable = (url) => /^(https?|ftps?|magnet):/i.test(url || '');

function humanBytes(n) {
  n = Number(n) || 0;
  if (n < 1024) return `${n} B`;
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
  return `${n.toFixed(n < 10 ? 1 : 0)} ${units[i]}`;
}

const humanSpeed = (n) => (Number(n) > 0 ? `${humanBytes(n)}/s` : '0 B/s');

//: "48 s", "3 min", "2 h 5 min" — how long, in words a glance can take in.
function humanEta(seconds) {
  const s = Math.round(Number(seconds));
  if (!Number.isFinite(s) || s < 0) return '';
  if (s < 60) return `${s} s`;
  if (s < 3600) return `${Math.round(s / 60)} min`;
  const h = Math.floor(s / 3600);
  const m = Math.round((s % 3600) / 60);
  return m ? `${h} h ${m} min` : `${h} h`;
}

//: Which link between the browser and aria2 is broken, from a ManagerLink reply:
//: "host" (the native-messaging helper is missing or crashed), "manager" (the
//: helper ran but nothing listens on the socket), or "" (it answered).
function linkProblem(reply) {
  if (!reply || (reply.status >= 200 && reply.status < 500)) return '';
  const error = String((reply.body && reply.body.error) || '');
  if (reply.status === 0 && /native host/i.test(error)) return 'host';
  return 'manager';
}

const INSTALL_HOST_CMD = 'python3 -m aria_download_manager --install-native-host';
const START_MANAGER_CMD = 'systemctl --user start aria-download-manager';

//: The running downloads summed up: bytes done of the total, and the time left
//: at the current speed. progress is -1 while any has no size yet.
function activeTotals(state) {
  let done = 0;
  let total = 0;
  let unknown = false;
  for (const d of (state && state.downloads) || []) {
    if (d.status !== 'active') continue;
    if (!d.total || d.isMetadata) { unknown = true; continue; }
    done += d.completed || 0;
    total += d.total;
  }
  const speed = Number((state && state.global && state.global.downloadSpeed) || 0);
  const left = Math.max(0, total - done);
  return {
    completed: done, total, left,
    progress: !unknown && total > 0 ? done / total : -1,
    eta: speed > 0 && total > 0 ? left / speed : -1,
  };
}

//: What a file is, from its name (or MIME type): a plain-word label and a
//: Material Symbols path for its tile. Shared by the dialog and the manager page.
const FILE_KINDS = {
  image: ['Disk image', 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 14.5a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9zm0-5.5a1 1 0 1 0 0 2 1 1 0 0 0 0-2z'],
  archive: ['Archive', 'M20 6h-8l-2-2H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zm-2 6h-2v2h2v2h-2v2h-2v-2h2v-2h-2v-2h2V8h2v2h2v2z'],
  video: ['Video', 'M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V4h-4z'],
  audio: ['Audio', 'M12 3v10.55A4 4 0 1 0 14 17V7h4V3h-6z'],
  picture: ['Picture', 'M21 19V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2zM8.5 13.5l2.5 3 3.5-4.5 4.5 6H5l3.5-4.5z'],
  document: ['Document', 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z'],
  app: ['App package', 'M20 6h-4V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v2H4a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zM10 4h4v2h-4V4z'],
  torrent: ['Torrent', 'M18 16.08c-.76 0-1.44.3-1.96.77L8.91 12.7c.05-.23.09-.46.09-.7s-.04-.47-.09-.7l7.05-4.11A2.99 2.99 0 0 0 21 5a3 3 0 1 0-5.91.7L8.04 9.81A3 3 0 1 0 6 15c.79 0 1.5-.31 2.04-.81l7.12 4.16c-.05.21-.08.43-.08.65A2.92 2.92 0 1 0 18 16.08z'],
  page: ['Web page', 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1 17.93A8 8 0 0 1 4 12c0-.62.08-1.21.21-1.79L9 15v1a2 2 0 0 0 2 2v1.93zm6.9-2.54A2 2 0 0 0 16 16h-1v-3a1 1 0 0 0-1-1H8v-2h2a1 1 0 0 0 1-1V7h2a2 2 0 0 0 2-2v-.41A7.99 7.99 0 0 1 17.9 17.39z'],
  file: ['File', 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zm-1 7V3.5L18.5 9H13z'],
};

const KIND_BY_EXT = {
  image: ['iso', 'img', 'qcow2', 'vdi', 'vmdk', 'dmg'],
  archive: ['zip', '7z', 'rar', 'gz', 'xz', 'zst', 'bz2', 'tar', 'tgz', 'txz'],
  video: ['mkv', 'mp4', 'webm', 'avi', 'mov', 'm4v', 'wmv', 'flv', 'ts'],
  audio: ['mp3', 'flac', 'ogg', 'opus', 'wav', 'm4a', 'aac'],
  picture: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'avif'],
  document: ['pdf', 'epub', 'mobi', 'doc', 'docx', 'odt', 'txt', 'md'],
  app: ['deb', 'rpm', 'appimage', 'exe', 'msi', 'pkg', 'apk', 'flatpak', 'whl'],
  torrent: ['torrent'],
  page: ['html', 'htm', 'php'],
};

function fileKind(name, mime) {
  const ext = (String(name || '').toLowerCase().match(/\.([a-z0-9]+)$/) || [])[1] || '';
  for (const [kind, exts] of Object.entries(KIND_BY_EXT)) {
    if (exts.includes(ext)) return { kind, label: FILE_KINDS[kind][0], path: FILE_KINDS[kind][1] };
  }
  const m = String(mime || '').toLowerCase();
  const byMime = m.startsWith('video/') ? 'video' : m.startsWith('audio/') ? 'audio'
    : m.startsWith('image/') ? 'picture' : m.includes('pdf') ? 'document'
      : /zip|compressed|x-tar|x-7z|x-rar/.test(m) ? 'archive' : m.includes('iso9660') ? 'image'
        : m.startsWith('text/html') ? 'page' : 'file';
  return { kind: byMime, label: FILE_KINDS[byMime][0], path: FILE_KINDS[byMime][1] };
}
