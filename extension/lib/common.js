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
  // Say so when a download is sent to the manager…
  notify: true,
  // …and, separately, when something fails (on unless turned off).
  notifyErrors: true,
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
