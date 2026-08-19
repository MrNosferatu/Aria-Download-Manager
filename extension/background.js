/* Background worker: intercepts the browser's own downloads, serves the
   context menus, and does every request to the manager (so page cookies —
   including HttpOnly ones — can be read through the cookies API). */
'use strict';

// Chrome runs this as a service worker and needs the shared code pulled in;
// Firefox lists both files in manifest background.scripts instead.
if (typeof importScripts === 'function') importScripts('lib/common.js');

const RECENT_LIMIT = 20;

// Downloads we cancelled ourselves, so onChanged does not report them as the
// user's own interrupted downloads.
const handedOff = new Set();

/* ----------------------------------------------------------------- notify */
function notify(message, isError) {
  api.notifications.create({
    type: 'basic',
    iconUrl: api.runtime.getURL('icons/icon-128.png'),
    title: isError ? 'aria2c manager — failed' : 'aria2c manager',
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
    cookie: item.cookie !== undefined ? item.cookie : await cookieHeaderFor(url),
    userAgent: navigator.userAgent,
    dir: settings.dir || null,
    paused: !!settings.paused,
    source: item.source || hostOf(item.referer || url) || 'extension',
  };
  await request(settings.server, '/api/intake/add', payload);
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
    await report(settings, `queued ${name}`, false, tabId);
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
    await report(settings, 'no links to send', true, tabId);
    return { ok: false };
  }
  try {
    await request(settings.server, '/api/intake/add', {
      urls,
      referer: context.referer || '',
      cookie: context.cookie !== undefined ? context.cookie : await cookieHeaderFor(urls[0]),
      userAgent: navigator.userAgent,
      dir: settings.dir || null,
      paused: !!settings.paused,
      source: hostOf(context.referer || urls[0]) || 'extension',
    });
    await remember(`${urls.length} links`);
    await report(settings, `queued ${urls.length} link(s)`, false, tabId);
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
  if (!settings.intercept) return;
  if (!/^https?:/i.test(item.url || '')) return;      // blob:/data: stay local
  if (isBlocked(settings, item.url)) return;
  if (item.byExtensionId && item.byExtensionId === api.runtime.id) return;
  if (settings.minSizeMB > 0 && item.totalBytes > 0
      && item.totalBytes < settings.minSizeMB * 1024 * 1024) {
    return;
  }

  handedOff.add(item.id);
  try {
    // Cancel first: the browser has already opened its own connection, and on
    // a one-shot link letting both run can burn the token.
    await api.downloads.cancel(item.id);
  } catch { /* already finished — carry on and queue it anyway */ }
  try {
    await api.downloads.erase({ id: item.id });
  } catch { /* leaving the row is harmless */ }

  const name = item.filename ? item.filename.split(/[\\/]/).pop() : '';
  const result = await sendOne({
    url: item.url,
    filename: name,
    referer: item.referrer || '',
    source: hostOf(item.referrer || item.url),
  }, undefined);

  if (!result.ok) {
    notify(`could not hand off ${name || item.url} — ${result.error}`, true);
  }
  handedOff.delete(item.id);
});

/* ------------------------------------------------------------ context menus */
const MENUS = [
  { id: 'link', title: 'Send this link to aria2c', contexts: ['link'] },
  { id: 'page', title: 'Send this page URL to aria2c', contexts: ['page'] },
  { id: 'selection', title: 'Send links in the selection to aria2c', contexts: ['selection'] },
  { id: 'all', title: 'Send ALL downloadable links on this page', contexts: ['page'] },
  { id: 'media', title: 'Send this media file to aria2c', contexts: ['image', 'video', 'audio'] },
];

function buildMenus() {
  api.contextMenus.removeAll(() => {
    for (const menu of MENUS) api.contextMenus.create(menu);
  });
}

api.runtime.onInstalled.addListener(buildMenus);
api.runtime.onStartup.addListener(buildMenus);

api.contextMenus.onClicked.addListener(async (info, tab) => {
  const tabId = tab && tab.id;
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
        notify('this page does not allow the extension to read its links', true);
        return;
      }
      sendMany((reply && reply.urls) || [], { referer: info.pageUrl, cookie: reply && reply.cookie }, tabId);
      break;
    }
  }
});

/* ----------------------------------------------------------------- badge */
async function refreshBadge() {
  const settings = await loadSettings();
  let text = '';
  let colour = '#4c8dff';
  try {
    const state = await request(settings.server, '/api/state');
    const counts = state.counts || {};
    const active = counts.active || 0;
    const waiting = (counts.waiting || 0) + (counts.paused || 0);
    text = active ? String(active) : (waiting ? `${waiting}` : '');
    if (!active && waiting) colour = '#8a8f98';
  } catch {
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
        const settings = await loadSettings();
        try {
          sendResponse({ ok: true, info: await request(settings.server, '/api/intake/ping') });
        } catch (err) {
          sendResponse({ ok: false, error: err.message });
        }
        break;
      }
      case 'state': {
        const settings = await loadSettings();
        try {
          sendResponse({ ok: true, state: await request(settings.server, '/api/state') });
        } catch (err) {
          sendResponse({ ok: false, error: err.message });
        }
        break;
      }
      case 'refreshBadge':
        await refreshBadge();
        sendResponse({ ok: true });
        break;
      default:
        sendResponse({ ok: false, error: `unknown message ${message.type}` });
    }
  })();
  return true;  // keep the channel open for the async reply
});
