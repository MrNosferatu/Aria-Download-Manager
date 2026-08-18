// ==UserScript==
// @name         aria2c manager — download catcher
// @namespace    https://github.com/local/aria2c-manager
// @version      1.0.0
// @description  Send downloads to your local aria2c-manager, with the page's cookies, referer and user-agent.
// @author       you
// @match        *://*/*
// @run-at       document-idle
// @grant        GM_xmlhttpRequest
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_registerMenuCommand
// @grant        GM_notification
// @grant        GM_cookie
// @connect      127.0.0.1
// @connect      localhost
// @noframes
// ==/UserScript==

/* eslint-env browser, greasemonkey */
(function () {
  'use strict';

  const DEFAULTS = {
    server: 'http://127.0.0.1:6810',
    // Auto-capture left-clicks on links that look like downloads.
    capture: true,
    // Always capture magnet: links (the browser can rarely do anything useful).
    captureMagnets: true,
    // Alt+click sends any link, even when capture is off.
    altClick: true,
    dir: '',
    paused: false,
    notify: true,
    // Skip files smaller than this (MiB) using a HEAD probe. 0 disables the probe.
    minSizeMB: 0,
    // Automatically drive hoster pages (wait out countdowns, submit once the
    // verification box clears, hand the link back). Only runs when started from
    // the web UI's "Open page" button or the menu entry — never while browsing.
    autoFlow: true,
    extensions: [
      '7z', 'apk', 'appimage', 'avi', 'bin', 'bz2', 'deb', 'dmg', 'epub', 'exe',
      'flac', 'flv', 'gz', 'img', 'iso', 'm4a', 'm4v', 'mkv', 'mobi', 'mov',
      'mp3', 'mp4', 'msi', 'ogg', 'pdf', 'pkg', 'rar', 'rpm', 'tar', 'tgz',
      'torrent', 'txz', 'wav', 'webm', 'whl', 'xz', 'zip', 'zst',
    ],
    blockedHosts: [],
  };

  const cfg = {};
  for (const [key, value] of Object.entries(DEFAULTS)) {
    cfg[key] = GM_getValue(key, value);
  }
  const save = (key, value) => { cfg[key] = value; GM_setValue(key, value); };

  /* ------------------------------------------------------------- feedback */
  let toastHost = null;

  function toast(message, kind = 'ok') {
    if (!cfg.notify) return;
    if (!toastHost) {
      toastHost = document.createElement('div');
      Object.assign(toastHost.style, {
        position: 'fixed', right: '16px', bottom: '16px', zIndex: 2147483647,
        display: 'flex', flexDirection: 'column', gap: '8px', pointerEvents: 'none',
      });
      document.body.append(toastHost);
    }
    const el = document.createElement('div');
    el.textContent = `aria2c: ${message}`;
    Object.assign(el.style, {
      background: kind === 'error' ? '#3a1a1f' : '#161a21',
      color: kind === 'error' ? '#ff8f99' : '#e6e9ef',
      border: `1px solid ${kind === 'error' ? '#5a2029' : '#272d38'}`,
      borderLeft: `3px solid ${kind === 'error' ? '#ff5f6d' : '#4c8dff'}`,
      borderRadius: '8px', padding: '9px 14px', font: '13px/1.4 system-ui, sans-serif',
      maxWidth: '380px', boxShadow: '0 8px 24px rgba(0,0,0,.45)',
    });
    toastHost.append(el);
    setTimeout(() => el.remove(), kind === 'error' ? 6000 : 2800);
  }

  /* ----------------------------------------------------------- transport */
  function request(path, payload) {
    return new Promise((resolve, reject) => {
      GM_xmlhttpRequest({
        method: payload ? 'POST' : 'GET',
        url: cfg.server.replace(/\/+$/, '') + path,
        headers: { 'Content-Type': 'application/json' },
        data: payload ? JSON.stringify(payload) : undefined,
        timeout: 15000,
        onload: (res) => {
          let body = null;
          try { body = JSON.parse(res.responseText); } catch { /* not json */ }
          if (res.status >= 200 && res.status < 300) resolve(body || {});
          else reject(new Error((body && (body.error || body.detail)) || `HTTP ${res.status}`));
        },
        onerror: () => reject(new Error('cannot reach the manager — is it running?')),
        ontimeout: () => reject(new Error('request timed out')),
      });
    });
  }

  function headSize(url) {
    return new Promise((resolve) => {
      GM_xmlhttpRequest({
        method: 'HEAD',
        url,
        timeout: 6000,
        onload: (res) => {
          const match = /content-length:\s*(\d+)/i.exec(res.responseHeaders || '');
          resolve(match ? Number(match[1]) : null);
        },
        onerror: () => resolve(null),
        ontimeout: () => resolve(null),
      });
    });
  }

  /* --------------------------------------------------------------- logic */
  function filenameFrom(url, anchor) {
    if (anchor && anchor.getAttribute('download')) {
      const name = anchor.getAttribute('download').trim();
      if (name) return name.split('/').pop();
    }
    try {
      const path = new URL(url, location.href).pathname;
      return decodeURIComponent(path.split('/').filter(Boolean).pop() || '');
    } catch {
      return '';
    }
  }

  function looksDownloadable(url, anchor) {
    if (/^magnet:/i.test(url)) return cfg.captureMagnets;
    if (!/^https?:\/\//i.test(url)) return false;
    try {
      const parsed = new URL(url, location.href);
      if (cfg.blockedHosts.some((h) => parsed.hostname.endsWith(h))) return false;
      if (anchor && anchor.hasAttribute('download')) return true;
      const ext = (parsed.pathname.split('.').pop() || '').toLowerCase();
      return cfg.extensions.includes(ext);
    } catch {
      return false;
    }
  }

  async function send(url, { anchor = null, filename = null, quiet = false } = {}) {
    if (!url) return false;
    if (cfg.minSizeMB > 0 && /^https?:/i.test(url)) {
      const size = await headSize(url);
      if (size != null && size < cfg.minSizeMB * 1024 * 1024) {
        if (!quiet) toast(`skipped (${(size / 1048576).toFixed(1)} MiB < ${cfg.minSizeMB} MiB)`);
        return false;
      }
    }
    const payload = {
      url,
      filename: filename ?? filenameFrom(url, anchor),
      referer: location.href,
      cookie: document.cookie || '',
      userAgent: navigator.userAgent,
      dir: cfg.dir || null,
      paused: !!cfg.paused,
      source: location.hostname,
    };
    try {
      await request('/api/userscript/add', payload);
      if (!quiet) toast(`queued ${payload.filename || url}`);
      return true;
    } catch (err) {
      toast(err.message, 'error');
      return false;
    }
  }

  /* ------------------------------------------------------------- capture */
  document.addEventListener('click', (event) => {
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey) return;
    const anchor = event.target.closest && event.target.closest('a[href]');
    if (!anchor) return;
    const url = anchor.href;
    if (!url || /^(javascript|blob|data):/i.test(url)) return;

    const viaAlt = cfg.altClick && event.altKey;
    if (!viaAlt && (!cfg.capture || !looksDownloadable(url, anchor))) return;
    if (viaAlt && !/^(https?|magnet|ftps?):/i.test(url)) return;

    event.preventDefault();
    event.stopPropagation();
    send(url, { anchor });
  }, true);

  /* --------------------------------------------------------- menu commands */
  const label = (name, on) => `${on ? '✅' : '⬜'} ${name}`;

  GM_registerMenuCommand('⬇ Send this page URL to aria2c', () => send(location.href));

  GM_registerMenuCommand('⬇ Send selected links to aria2c', async () => {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed) { toast('nothing selected', 'error'); return; }
    const range = selection.getRangeAt(0);
    const anchors = [...document.querySelectorAll('a[href]')]
      .filter((a) => range.intersectsNode(a));
    if (!anchors.length) { toast('no links inside the selection', 'error'); return; }
    let sent = 0;
    for (const anchor of anchors) {
      if (await send(anchor.href, { anchor, quiet: true })) sent++;
    }
    toast(`queued ${sent}/${anchors.length} link(s)`);
  });

  GM_registerMenuCommand('⬇ Send ALL downloadable links on this page', async () => {
    const anchors = [...document.querySelectorAll('a[href]')]
      .filter((a) => looksDownloadable(a.href, a));
    const urls = [...new Set(anchors.map((a) => a.href))];
    if (!urls.length) { toast('no downloadable links found', 'error'); return; }
    if (!confirm(`Send ${urls.length} link(s) to aria2c?`)) return;
    try {
      await request('/api/userscript/add', {
        urls,
        referer: location.href,
        cookie: document.cookie || '',
        userAgent: navigator.userAgent,
        dir: cfg.dir || null,
        paused: !!cfg.paused,
        source: location.hostname,
      });
      toast(`queued ${urls.length} link(s)`);
    } catch (err) {
      toast(err.message, 'error');
    }
  });

  GM_registerMenuCommand('⬇ Send a URL by hand…', () => {
    const url = prompt('URL / magnet to download:', '');
    if (url && url.trim()) send(url.trim());
  });

  /* ------------------------------------------------------- hoster queue */
  async function queueHosterPages(urls) {
    try {
      const out = await request('/api/userscript/hoster', {
        urls,
        options: cfg.dir ? { dir: cfg.dir } : {},
      });
      toast(`queued ${out.count} page(s) in the hoster queue`);
    } catch (err) {
      toast(err.message, 'error');
    }
  }

  GM_registerMenuCommand('📥 Queue THIS PAGE in the hoster queue', () => {
    queueHosterPages([location.href]);
  });

  GM_registerMenuCommand('📥 Queue hoster links on this page…', async () => {
    let domains = [];
    try {
      domains = (await request('/api/userscript/ping')).hosterDomains || [];
    } catch (err) {
      toast(err.message, 'error');
      return;
    }
    const urls = [...new Set([...document.querySelectorAll('a[href^="http"]')]
      .map((a) => a.href)
      .filter((href) => {
        try {
          const host = new URL(href).hostname.replace(/^www\./, '');
          return domains.some((d) => host === d || host.endsWith('.' + d));
        } catch { return false; }
      }))];
    if (!urls.length) { toast('no links to supported hosts found', 'error'); return; }
    if (!confirm(`Queue ${urls.length} hoster page(s)?`)) return;
    queueHosterPages(urls);
  });

  /* ------------------------------------------------- cookie sharing ---- */
  function readCookies() {
    // cf_clearance is HttpOnly, so document.cookie cannot see it. GM_cookie can.
    return new Promise((resolve) => {
      if (typeof GM_cookie === 'undefined' || !GM_cookie.list) {
        resolve({ jar: parseDocumentCookie(), httpOnly: false });
        return;
      }
      try {
        GM_cookie.list({ url: location.href }, (cookies, error) => {
          if (error || !Array.isArray(cookies)) {
            resolve({ jar: parseDocumentCookie(), httpOnly: false });
            return;
          }
          const jar = {};
          for (const c of cookies) if (c && c.name) jar[c.name] = c.value;
          resolve({ jar, httpOnly: true });
        });
      } catch {
        resolve({ jar: parseDocumentCookie(), httpOnly: false });
      }
    });
  }

  function parseDocumentCookie() {
    const jar = {};
    for (const part of (document.cookie || '').split(';')) {
      const [name, ...rest] = part.trim().split('=');
      if (name && rest.length) jar[name] = rest.join('=');
    }
    return jar;
  }

  async function shareCookies(quiet = false) {
    const { jar, httpOnly } = await readCookies();
    if (!Object.keys(jar).length) {
      if (!quiet) toast('no cookies to share for this site', 'error');
      return false;
    }
    try {
      const out = await request('/api/hoster/cookies', {
        domain: location.hostname,
        cookies: jar,
        user_agent: navigator.userAgent,
      });
      const clearance = 'cf_clearance' in jar;
      if (!quiet) {
        toast(`shared ${out.cookies} cookie(s) for ${out.domain}`
          + (clearance ? ' incl. Cloudflare clearance' : '')
          + (out.requeued ? ` — retrying ${out.requeued} job(s)` : '')
          + (!httpOnly && !clearance ? ' (grant GM_cookie to include HttpOnly ones)' : ''));
      }
      return true;
    } catch (err) {
      if (!quiet) toast(err.message, 'error');
      return false;
    }
  }

  GM_registerMenuCommand('🔐 Share this site’s cookies with the manager', () => shareCookies());

  /* --------------------------------------------- automatic page flow ---- */
  const AUTO_KEY = 'a2m-auto-flow';
  const CHALLENGE_INPUTS = [
    'cf-turnstile-response',      // Cloudflare Turnstile
    'g-recaptcha-response',       // reCAPTCHA
    'h-captcha-response',         // hCaptcha
  ];

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const stopAutoFlow = (why) => {
    sessionStorage.removeItem(AUTO_KEY);
    sessionStorage.removeItem(`${AUTO_KEY}-n`);
    if (why) toast(why, 'error');
  };

  function findGeneratedLink() {
    const anchors = [...document.querySelectorAll('a[href^="http"]')];
    return (anchors.find((a) => a.id === 'direct_link' || a.id === 'downloadButton')
      || anchors.find((a) => /btn-dow|link-dl|dlbutton/i.test(a.className))
      || anchors.find((a) => /\.(zip|rar|7z|iso|mkv|mp4|bin|exe|apk|pdf|tar|gz|zst)(\?|$)/i.test(a.href))
    )?.href || null;
  }

  function findOpForm() {
    for (const form of document.querySelectorAll('form')) {
      const op = form.querySelector('[name="op"]');
      if (op && op.value) return { form, op: op.value };
    }
    return null;
  }

  async function waitForCountdown() {
    const readSeconds = () => {
      for (const sel of ['#countdown', '.seconds', '#countdown_str span', '[id^=countdown]']) {
        const el = document.querySelector(sel);
        const n = el && parseInt((el.textContent || '').replace(/\D/g, ''), 10);
        if (Number.isFinite(n)) return n;
      }
      return null;
    };
    let seconds = readSeconds();
    if (seconds == null) return;
    toast(`waiting out the ${seconds}s countdown…`);
    const deadline = Date.now() + (seconds + 20) * 1000;
    while (Date.now() < deadline) {
      await sleep(1000);
      seconds = readSeconds();
      if (seconds == null || seconds <= 0) return;
    }
  }

  async function waitForChallenge(form) {
    const input = CHALLENGE_INPUTS
      .map((name) => form.querySelector(`[name="${name}"]`)
        || document.querySelector(`[name="${name}"]`))
      .find(Boolean);
    if (!input) return true;                 // nothing to wait for
    if ((input.value || '').length > 10) return true;  // invisible mode already solved it
    toast('tick the verification box — I will submit as soon as it clears', 'ok');
    const deadline = Date.now() + 300000;    // five minutes of patience
    while (Date.now() < deadline) {
      await sleep(700);
      if ((input.value || '').length > 10) { toast('verified — submitting'); return true; }
    }
    return false;
  }

  async function runAutoFlow() {
    const steps = Number(sessionStorage.getItem(`${AUTO_KEY}-n`) || 0);
    if (steps > 5) { stopAutoFlow('gave up: too many steps on this page'); return; }
    sessionStorage.setItem(AUTO_KEY, '1');
    sessionStorage.setItem(`${AUTO_KEY}-n`, String(steps + 1));

    // Share cookies early: a Cloudflare clearance here may let the manager
    // resolve this host on its own next time.
    shareCookies(true);

    const link = findGeneratedLink();
    if (link) {
      const ok = await send(link, { quiet: true });
      stopAutoFlow();
      toast(ok ? 'link sent to the queue — done here' : 'found a link but could not send it',
        ok ? 'ok' : 'error');
      return;
    }

    const found = findOpForm();
    if (!found) { stopAutoFlow('no download form or link found on this page'); return; }
    if (found.op === 'download1') {
      toast('starting the download flow…');
      found.form.submit();
      return;
    }
    if (found.op === 'download2') {
      await waitForCountdown();
      if (!await waitForChallenge(found.form)) {
        stopAutoFlow('timed out waiting for the verification box');
        return;
      }
      found.form.submit();
      return;
    }
    stopAutoFlow(`unexpected form step "${found.op}"`);
  }

  GM_registerMenuCommand('▶ Auto-run this hoster page (wait + submit + hand back)', () => {
    sessionStorage.removeItem(`${AUTO_KEY}-n`);
    runAutoFlow();
  });

  // The web UI's "Open page" button adds #a2m-auto, which starts this
  // automatically; the flag then carries across the flow's page transitions.
  if (cfg.autoFlow
      && (location.hash.includes('a2m-auto') || sessionStorage.getItem(AUTO_KEY) === '1')) {
    setTimeout(runAutoFlow, 600);
  }

  GM_registerMenuCommand('📤 Send this page’s generated link to the queue', async () => {
    // After you solve a captcha, the direct link is on the page. Posting it with
    // this page as the referer lets the manager match it to the waiting job.
    const candidates = [...document.querySelectorAll('a[href^="http"]')]
      .filter((a) => a.id === 'direct_link'
        || /btn-dow|link-dl|dlbutton|downloadButton/i.test(a.className + ' ' + a.id)
        || /\.(zip|rar|7z|iso|mkv|mp4|part\d+\.rar|bin|exe|apk|pdf)(\?|$)/i.test(a.href));
    const url = candidates.length
      ? candidates[0].href
      : prompt('Paste the generated download link:', '');
    if (!url) { toast('no generated link found on this page', 'error'); return; }
    const ok = await send(url, { quiet: true });
    toast(ok ? 'link sent — the queue will take it from here' : 'could not send the link',
      ok ? 'ok' : 'error');
  });

  GM_registerMenuCommand(label('Auto-capture download links', cfg.capture), () => {
    save('capture', !cfg.capture);
    toast(`auto-capture ${cfg.capture ? 'on' : 'off'} (reload to update this menu)`);
  });

  GM_registerMenuCommand(label('Alt+click sends any link', cfg.altClick), () => {
    save('altClick', !cfg.altClick);
    toast(`alt+click ${cfg.altClick ? 'on' : 'off'}`);
  });

  GM_registerMenuCommand(label('Auto-run hoster pages when opened from the UI', cfg.autoFlow), () => {
    save('autoFlow', !cfg.autoFlow);
    toast(`hoster auto-flow ${cfg.autoFlow ? 'on' : 'off'}`);
  });

  GM_registerMenuCommand(label('Add downloads paused', cfg.paused), () => {
    save('paused', !cfg.paused);
    toast(`new downloads start ${cfg.paused ? 'paused' : 'immediately'}`);
  });

  GM_registerMenuCommand('⚙ Server URL…', () => {
    const value = prompt('aria2c-manager base URL:', cfg.server);
    if (value && value.trim()) { save('server', value.trim()); toast(`server = ${cfg.server}`); }
  });

  GM_registerMenuCommand('⚙ Default save directory…', () => {
    const value = prompt('Directory (blank = aria2 default):', cfg.dir);
    if (value !== null) { save('dir', value.trim()); toast(`dir = ${cfg.dir || 'aria2 default'}`); }
  });

  GM_registerMenuCommand('⚙ File extensions to capture…', () => {
    const value = prompt('Comma-separated extensions:', cfg.extensions.join(','));
    if (value === null) return;
    save('extensions', value.split(',').map((s) => s.trim().replace(/^\./, '').toLowerCase()).filter(Boolean));
    toast(`${cfg.extensions.length} extension(s) captured`);
  });

  GM_registerMenuCommand('⚙ Minimum size (MiB, 0 = off)…', () => {
    const value = prompt('Skip files smaller than (MiB):', String(cfg.minSizeMB));
    if (value === null) return;
    save('minSizeMB', Math.max(0, Number(value) || 0));
    toast(`minimum size = ${cfg.minSizeMB} MiB`);
  });

  GM_registerMenuCommand('⚙ Skip this site (auto-capture)', () => {
    const hosts = new Set(cfg.blockedHosts);
    hosts.has(location.hostname) ? hosts.delete(location.hostname) : hosts.add(location.hostname);
    save('blockedHosts', [...hosts]);
    toast(`${location.hostname} ${hosts.has(location.hostname) ? 'blocked' : 'unblocked'}`);
  });

  GM_registerMenuCommand('🔎 Test connection', async () => {
    try {
      const info = await request('/api/userscript/ping');
      toast(`connected — ${info.name} ${info.version}, aria2 ${info.aria2 ? 'up' : 'down'}`);
    } catch (err) {
      toast(err.message, 'error');
    }
  });

  GM_registerMenuCommand('🖥 Open the web UI', () => window.open(cfg.server, '_blank'));
})();
