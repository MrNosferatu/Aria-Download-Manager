/* Background worker: intercepts the browser's own downloads, serves the
   context menus, and does every request to the manager (so page cookies —
   including HttpOnly ones — can be read through the cookies API). */
'use strict';

// Chrome runs this as a service worker and needs the shared code pulled in;
// Firefox lists both files in manifest background.scripts instead.
if (typeof importScripts === 'function') importScripts('lib/common.js', 'lib/link.js');

const RECENT_LIMIT = 20;

// Downloads we cancelled ourselves, so onChanged does not report them as the
// user's own interrupted downloads.
const handedOff = new Set();

/* --------------------------------------------------------- manager health */
/* Interception is destructive: it cancels the browser's own download before
   handing the URL over. If the manager is not there to take it, the user is
   left with no download at all — so nothing is cancelled until we know there is
   somewhere for it to go. The badge poll already talks to the manager every
   30s, so its result is reused rather than adding a probe to every download. */

const health = { ok: null, at: 0 };
const HEALTH_FRESH_MS = 20000;

function noteHealth(ok) {
  health.ok = ok;
  health.at = Date.now();
}

async function managerReachable() {
  if (health.ok !== null && Date.now() - health.at < HEALTH_FRESH_MS) return health.ok;
  try {
    await request('/api/intake/ping');
    noteHealth(true);
  } catch {
    noteHealth(false);
  }
  return health.ok;
}

/* ----------------------------------------------------------------- notify */
function notify(message, isError) {
  api.notifications.create({
    type: 'basic',
    iconUrl: api.runtime.getURL('icons/icon-128.png'),
    title: isError ? 'Aria Download Manager: not added' : 'Aria Download Manager',
    message: String(message).slice(0, 300),
  });
}

async function report(settings, message, isError, tabId) {
  if (!settings.notify) return;
  // Prefer an in-page toast when the action came from a tab: it is quieter and
  // lands where the user is looking.
  if (settings.pageToasts && tabId !== undefined && tabId !== null) {
    try {
      await api.tabs.sendMessage(tabId, { type: 'toast', message, kind: isError ? 'error' : 'ok' });
      return;
    } catch { /* no content script in that tab — fall through */ }
  }
  notify(message, isError);
}

/* ---------------------------------------------------------- video sniffer */
/* A modern player never puts a downloadable URL in the page: it fetches an HLS
   or DASH manifest and feeds segments to the <video> element through Media
   Source Extensions, so video.src is a blob: handle to a buffer in memory. The
   manifest is still plainly visible on the network, though, and it is a
   published list of every quality the site will serve. So: watch the traffic,
   not the DOM. Observation only — MV3 has no blocking webRequest and none is
   needed here. */

const MANIFEST_RE = /\.(m3u8|m3u|mpd)(\?|#|$)/i;
const DIRECT_RE = /\.(mp4|webm|mkv|mov|m4v|flv)(\?|#|$)/i;
// Segments are the *parts* a manifest lists. There can be thousands of them and
// none is worth downloading alone, so they never enter the registry.
const SEGMENT_RE = /\.(ts|m4s|aac|vtt|key)(\?|#|$)/i;

const MANIFEST_TYPES = new Set([
  'application/vnd.apple.mpegurl', 'application/x-mpegurl',
  'audio/mpegurl', 'audio/x-mpegurl', 'application/dash+xml',
]);
const DIRECT_TYPES = /^video\/(mp4|webm|x-matroska|quicktime|x-flv)/i;

const CANDIDATES_PER_TAB = 12;
// A webRequest listener cannot await, so the settings it needs are kept warm.
let snifferSettings = null;
loadSettings().then((s) => { snifferSettings = s; });
api.storage.onChanged.addListener(() => { loadSettings().then((s) => { snifferSettings = s; }); });
// tabId -> Map(url -> {url, contentType, kind, title, ts})
const seenMedia = new Map();

function classify(url, contentType) {
  const base = (contentType || '').split(';')[0].trim().toLowerCase();
  if (MANIFEST_TYPES.has(base)) return base === 'application/dash+xml' ? 'dash' : 'hls';
  if (DIRECT_TYPES.test(base)) return 'direct';
  if (SEGMENT_RE.test(url)) return '';
  if (MANIFEST_RE.test(url)) return /\.mpd(\?|#|$)/i.test(url) ? 'dash' : 'hls';
  if (DIRECT_RE.test(url)) return 'direct';
  return '';
}

function noteMedia(tabId, url, contentType, kind) {
  if (tabId === undefined || tabId < 0) return;
  let jar = seenMedia.get(tabId);
  if (!jar) { jar = new Map(); seenMedia.set(tabId, jar); }
  // A live playlist is re-fetched every few seconds; keying by URL keeps one
  // entry rather than a scrolling wall of the same stream.
  if (!jar.has(url)) {
    jar.set(url, { url, contentType: contentType || '', kind, ts: Date.now() });
    while (jar.size > CANDIDATES_PER_TAB) jar.delete(jar.keys().next().value);
  }
  updateVideoBadge(tabId, jar.size);
}

function updateVideoBadge(tabId, count) {
  api.tabs.sendMessage(tabId, { type: 'videoFound', count })
    .catch(() => { /* no content script in that tab */ });
}

let snifferStarted = false;

function startSniffer() {
  if (snifferStarted) return;
  if (!api.webRequest || !api.webRequest.onHeadersReceived) return;
  snifferStarted = true;
  api.webRequest.onHeadersReceived.addListener(
    (details) => {
      if (!snifferSettings || !snifferSettings.enabled) return;
      if (snifferSettings.videoSniffer === false) return;
      // documentUrl is the page the request belongs to, which is what an
      // exclusion by domain is really about — the stream itself usually comes
      // from a CDN on an unrelated host.
      if (isBlocked(snifferSettings, details.url, details.documentUrl || details.originUrl)) return;
      const header = (details.responseHeaders || [])
        .find((h) => h.name.toLowerCase() === 'content-type');
      const kind = classify(details.url, header && header.value);
      if (kind) noteMedia(details.tabId, details.url, header && header.value, kind);
    },
    { urls: ['http://*/*', 'https://*/*'] },
    ['responseHeaders'],
  );

  // A page navigation makes everything gathered for the old page irrelevant.
  api.webRequest.onBeforeRequest.addListener(
    (details) => {
      if (details.type === 'main_frame') seenMedia.delete(details.tabId);
    },
    { urls: ['http://*/*', 'https://*/*'], types: ['main_frame'] },
  );
}

api.tabs.onRemoved.addListener((tabId) => seenMedia.delete(tabId));

function candidatesFor(tabId) {
  const jar = seenMedia.get(tabId);
  if (!jar) return [];
  // Manifests first: they carry a quality choice, a progressive file does not.
  const rank = { hls: 0, dash: 0, direct: 1 };
  return [...jar.values()].sort((a, b) => (rank[a.kind] - rank[b.kind]) || (b.ts - a.ts));
}

/* ------------------------------------------------------- manager handoff */
/* The manager does the work: it fetches the manifest, reads the qualities out
   of it, and runs the download. The extension's job is only to say which URL,
   with which credentials — which is the part only the browser knows. */

async function videoContext(candidate, sender) {
  const pageUrl = (sender.tab && sender.tab.url) || '';
  return {
    url: candidate.url,
    content_type: candidate.contentType || '',
    referer: pageUrl || undefined,
    // Read through the cookies API rather than document.cookie so HttpOnly
    // session cookies come too — without them a members-only stream probes as
    // an error page with no variants in it.
    cookie: (await cookieHeaderFor(candidate.url)) || undefined,
    user_agent: navigator.userAgent,
  };
}

async function probeVideo(candidate, sender) {
  try {
    const body = await videoContext(candidate, sender);
    body.title = candidate.title || (sender.tab && sender.tab.title) || '';
    const out = await request('/api/media/probe', body);
    return { ok: true, probe: out };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

async function downloadVideo(message, sender, tabId) {
  const settings = await loadSettings();
  try {
    const body = await videoContext(message.candidate, sender);
    body.title = message.title || (sender.tab && sender.tab.title) || '';
    body.variant = message.variant || undefined;
    body.variant_id = message.variantId || undefined;
    if (settings.dir) body.dir = settings.dir;
    const out = await request('/api/media/download', body);
    const label = out.kind === 'stream'
      ? `Downloading ${out.job.name}`
      : 'Video added';
    await report(settings, label, false, tabId);
    await refreshBadge();
    return { ok: true, result: out };
  } catch (err) {
    await report(settings, `Could not add the video: ${err.message}`, true, tabId);
    return { ok: false, error: err.message };
  }
}

/* ------------------------------------------------------------- cookie jar */
async function cookieHeaderFor(url) {
  try {
    const jar = await api.cookies.getAll({ url });
    return (jar || []).map((c) => `${c.name}=${c.value}`).join('; ');
  } catch {
    return '';
  }
}

/* ------------------------------------------------------------------ intake */
async function sendToManager(settings, item, tabId) {
  const url = item.url;
  if (!isFetchable(url)) throw new Error('that link is not something aria2 can fetch');

  const payload = {
    url,
    filename: item.filename || filenameFromUrl(url, item.downloadAttr),
    referer: item.referer || '',
    // From the cookie store, for the file's own URL: document.cookie would be
    // the wrong site's (the page, not the file host) and miss HttpOnly ones.
    cookie: await cookieHeaderFor(url),
    userAgent: navigator.userAgent,
    dir: settings.dir || null,
    paused: !!settings.paused,
    source: item.source || hostOf(item.referer || url) || 'extension',
  };
  await request('/api/intake/add', payload);
  await remember(payload.filename || url);
  return payload.filename || url;
}

async function remember(name) {
  const { recent = [] } = await api.storage.local.get({ recent: [] });
  recent.unshift({ name, at: Date.now() });
  await api.storage.local.set({ recent: recent.slice(0, RECENT_LIMIT) });
}

async function sendOne(item, tabId) {
  const settings = await loadSettings();
  try {
    const name = await sendToManager(settings, item, tabId);
    await report(settings, `Added ${name}`, false, tabId);
    refreshBadge();
    return { ok: true };
  } catch (err) {
    await report(settings, err.message, true, tabId);
    return { ok: false, error: err.message };
  }
}

async function sendMany(urls, context, tabId) {
  const settings = await loadSettings();
  if (!urls.length) {
    await report(settings, 'No links to add here.', true, tabId);
    return { ok: false };
  }
  // Cookies belong to the host a file is on, and one batch can span several
  // hosts, so each host's links go as their own batch with that host's cookies.
  const byHost = new Map();
  for (const url of urls) {
    const host = hostOf(url);
    if (!byHost.has(host)) byHost.set(host, []);
    byHost.get(host).push(url);
  }
  try {
    for (const group of byHost.values()) {
      await request('/api/intake/add', {
        urls: group,
        referer: context.referer || '',
        cookie: await cookieHeaderFor(group[0]),
        userAgent: navigator.userAgent,
        dir: settings.dir || null,
        paused: !!settings.paused,
        source: hostOf(context.referer || group[0]) || 'extension',
      });
    }
    await remember(`${urls.length} links`);
    await report(settings, `Added ${urls.length} link${urls.length === 1 ? '' : 's'}`, false, tabId);
    refreshBadge();
    return { ok: true, count: urls.length };
  } catch (err) {
    await report(settings, err.message, true, tabId);
    return { ok: false, error: err.message };
  }
}

/* ------------------------------------------- browser downloads → aria2c */
api.downloads.onCreated.addListener(async (item) => {
  const settings = await loadSettings();
  if (!settings.enabled) return;                      // master switch is off
  if (!settings.intercept) return;
  if (!/^https?:/i.test(item.url || '')) return;      // blob:/data: stay local
  // Both hosts count: the file's own, and the page that asked for it.
  if (isBlocked(settings, item.url, item.referrer)) return;
  if (item.byExtensionId && item.byExtensionId === api.runtime.id) return;
  if (settings.minSizeMB > 0 && item.totalBytes > 0
      && item.totalBytes < settings.minSizeMB * 1024 * 1024) {
    return;
  }

  // The whole point of this check: taking a download away from the browser and
  // then discovering there is nowhere to put it loses the download. If the
  // manager is not answering, do nothing at all and let the browser get on
  // with it — a download that works is better than one that was ours.
  if (!(await managerReachable())) {
    if (settings.notify) {
      notify('The manager is not running, so the browser is downloading this itself.', false);
    }
    return;
  }

  const name = item.filename ? item.filename.split(/[\\/]/).pop() : '';
  handedOff.add(item.id);
  try {
    // Cancel first: the browser has already opened its own connection, and on
    // a one-shot link letting both run can burn the token.
    await api.downloads.cancel(item.id);
  } catch { /* already finished — carry on and queue it anyway */ }
  try {
    await api.downloads.erase({ id: item.id });
  } catch { /* leaving the row is harmless */ }

  const result = await sendOne({
    url: item.url,
    filename: name,
    referer: item.referrer || '',
    source: hostOf(item.referrer || item.url),
  }, undefined);

  if (!result.ok) {
    // The manager answered the ping and then failed anyway — it died in the
    // gap, or rejected the URL. Either way the browser's download is already
    // cancelled, so hand it back rather than leaving the user with nothing.
    noteHealth(false);
    try {
      await api.downloads.download({ url: item.url });
      notify(`The manager could not take ${name || item.url}. The browser is downloading it instead.`, true);
    } catch (err) {
      notify(`Could not hand off ${name || item.url}: ${result.error}`, true);
    }
  }
  handedOff.delete(item.id);
});

/* ------------------------------------------------------------ context menus */
const MENUS = [
  { id: 'link', title: 'Download link with Aria', contexts: ['link'] },
  { id: 'page', title: 'Download this page with Aria', contexts: ['page'] },
  { id: 'selection', title: 'Download selected links with Aria', contexts: ['selection'] },
  { id: 'all', title: 'Download every file link on this page with Aria', contexts: ['page'] },
  { id: 'media', title: 'Download media with Aria', contexts: ['image', 'video', 'audio'] },
];

/* The exclusion list governs *automatic* behaviour — interception, click
   capture, the video button. It deliberately does not gag the context menu: a
   right-click on "Send this link to aria2c" is a deliberate act, and silently
   ignoring it because of a passive rule set months ago would be baffling. The
   master switch does apply, and takes the menus away entirely rather than
   leaving entries that do nothing. */
async function buildMenus() {
  const settings = await loadSettings();
  api.contextMenus.removeAll(() => {
    if (!settings.enabled) return;
    for (const menu of MENUS) api.contextMenus.create(menu);
  });
}

// Flipping the master switch has to take effect without a browser restart.
api.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local') return;
  if (changes.enabled) {
    buildMenus();
    refreshBadge();
    if (changes.enabled.newValue && !snifferStarted) startSniffer();
  }
  if (changes.videoSniffer && changes.videoSniffer.newValue && !snifferStarted) startSniffer();
});

api.runtime.onInstalled.addListener(buildMenus);
api.runtime.onStartup.addListener(buildMenus);

api.contextMenus.onClicked.addListener(async (info, tab) => {
  const tabId = tab && tab.id;
  const settings = await loadSettings();
  if (!settings.enabled) return;
  switch (info.menuItemId) {
    case 'link':
      sendOne({ url: info.linkUrl, referer: info.pageUrl }, tabId);
      break;
    case 'media':
      sendOne({ url: info.srcUrl || info.linkUrl, referer: info.pageUrl }, tabId);
      break;
    case 'page':
      sendOne({ url: info.pageUrl, referer: info.pageUrl }, tabId);
      break;
    case 'selection':
    case 'all': {
      if (tabId === undefined) return;
      let reply;
      try {
        reply = await api.tabs.sendMessage(tabId, {
          type: 'collect',
          scope: info.menuItemId === 'all' ? 'downloadable' : 'selection',
        });
      } catch {
        notify('This page does not let the extension read its links.', true);
        return;
      }
      sendMany((reply && reply.urls) || [], { referer: info.pageUrl }, tabId);
      break;
    }
  }
});

/* ----------------------------------------------------------------- badge */
async function refreshBadge() {
  const settings = await loadSettings();
  let text = '';
  let colour = '#4c8dff';
  if (!settings.enabled) {
    try {
      await api.action.setBadgeText({ text: 'off' });
      await api.action.setBadgeBackgroundColor({ color: '#6b7280' });
    } catch { /* action API missing */ }
    return;
  }
  try {
    const state = await request('/api/state');
    noteHealth(true);
    const counts = state.counts || {};
    const active = counts.active || 0;
    const waiting = (counts.waiting || 0) + (counts.paused || 0);
    text = active ? String(active) : (waiting ? `${waiting}` : '');
    if (!active && waiting) colour = '#8a8f98';
  } catch {
    noteHealth(false);
    text = '!';
    colour = '#ff5f6d';
  }
  try {
    await api.action.setBadgeText({ text });
    await api.action.setBadgeBackgroundColor({ color: colour });
  } catch { /* action API missing (very old builds) */ }
}

api.alarms.create('badge', { periodInMinutes: 0.5 });
api.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'badge') refreshBadge();
});
api.runtime.onStartup.addListener(refreshBadge);
api.runtime.onInstalled.addListener(refreshBadge);

loadSettings().then((settings) => {
  if (settings.enabled && settings.videoSniffer !== false) startSniffer();
});

/* --------------------------------------------------------------- messages */
api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const tabId = sender.tab && sender.tab.id;
  (async () => {
    switch (message.type) {
      case 'send':
        sendResponse(await sendOne(message.item, tabId));
        break;
      case 'sendMany':
        sendResponse(await sendMany(message.urls, message.context || {}, tabId));
        break;
      case 'ping': {
        try {
          sendResponse({ ok: true, info: await request('/api/intake/ping') });
        } catch (err) {
          sendResponse({ ok: false, error: err.message });
        }
        break;
      }
      case 'state': {
        try {
          sendResponse({ ok: true, state: await request('/api/state') });
        } catch (err) {
          sendResponse({ ok: false, error: err.message });
        }
        break;
      }
      case 'refreshBadge':
        await refreshBadge();
        sendResponse({ ok: true });
        break;
      case 'videoCandidates':
        sendResponse({ ok: true, candidates: candidatesFor(tabId) });
        break;
      case 'videoProbe':
        sendResponse(await probeVideo(message.candidate, sender));
        break;
      case 'videoDownload':
        sendResponse(await downloadVideo(message, sender, tabId));
        break;
      default:
        sendResponse({ ok: false, error: `unknown message ${message.type}` });
    }
  })();
  return true;  // keep the channel open for the async reply
});
