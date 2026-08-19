/* Shared helpers for every extension surface: background, content script,
   popup and options. Loaded as a classic script (no modules) so the same file
   works in a Chrome service worker and a Firefox event page. */
'use strict';

// Firefox exposes `browser`, Chrome only `chrome`. Both speak promises for the
// APIs used here (Chrome since MV3).
const api = globalThis.browser || globalThis.chrome;

const DEFAULTS = {
  server: 'http://127.0.0.1:6810',
  // Hand the browser's own downloads to aria2c instead of downloading them here.
  intercept: true,
  // Auto-capture left-clicks on links that look like downloads.
  capture: true,
  // Always capture magnet: links — the browser can rarely do anything useful.
  captureMagnets: true,
  // Alt+click sends any link, even when capture is off.
  altClick: true,
  dir: '',
  paused: false,
  notify: true,
  // In-page toasts (as well as the OS notifications the browser shows).
  pageToasts: true,
  // Skip files smaller than this (MiB). 0 disables the check.
  minSizeMB: 0,
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

const baseUrl = (server) => String(server || DEFAULTS.server).replace(/\/+$/, '');

async function request(server, path, payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  let res;
  try {
    res = await fetch(baseUrl(server) + path, {
      method: payload ? 'POST' : 'GET',
      headers: payload ? { 'Content-Type': 'application/json' } : undefined,
      body: payload ? JSON.stringify(payload) : undefined,
      signal: controller.signal,
    });
  } catch (err) {
    throw new Error(err.name === 'AbortError'
      ? 'request timed out'
      : 'cannot reach the manager — is it running?');
  } finally {
    clearTimeout(timer);
  }
  let body = null;
  try {
    body = await res.json();
  } catch { /* empty or non-JSON body */ }
  if (!res.ok) {
    const detail = body && (body.error || body.detail);
    throw new Error(typeof detail === 'string' ? detail : `HTTP ${res.status}`);
  }
  return body || {};
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

function isBlocked(settings, url) {
  const host = hostOf(url);
  return !!host && settings.blockedHosts.some((h) => host === h || host.endsWith('.' + h));
}

// Does this link look like a file rather than a page? Used for click capture;
// browser-initiated downloads skip this, since the browser already decided.
function looksDownloadable(settings, url, hasDownloadAttr) {
  if (/^magnet:/i.test(url)) return settings.captureMagnets;
  if (!/^https?:\/\//i.test(url)) return false;
  if (isBlocked(settings, url)) return false;
  if (hasDownloadAttr) return true;
  try {
    const ext = (new URL(url).pathname.split('.').pop() || '').toLowerCase();
    return settings.extensions.includes(ext);
  } catch {
    return false;
  }
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
