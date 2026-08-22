/* Content script: click capture, in-page toasts, and link harvesting for the
   context menu. All network work happens in the background worker. */
'use strict';

(() => {
  let settings = null;
  loadSettings().then((loaded) => { settings = loaded; });
  api.storage.onChanged.addListener(() => {
    loadSettings().then((loaded) => { settings = loaded; });
  });

  /* ------------------------------------------------------------- toasts */
  let host = null;

  function toast(message, kind) {
    if (!settings || !settings.pageToasts) return;
    if (!host) {
      host = document.createElement('div');
      Object.assign(host.style, {
        position: 'fixed', right: '16px', bottom: '16px', zIndex: 2147483647,
        display: 'flex', flexDirection: 'column', gap: '8px', pointerEvents: 'none',
      });
      (document.body || document.documentElement).append(host);
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
    host.append(el);
    setTimeout(() => el.remove(), kind === 'error' ? 6000 : 2800);
  }

  /* ------------------------------------------------------------ capture */
  document.addEventListener('click', (event) => {
    if (!settings || !settings.enabled) return;
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey) return;
    const anchor = event.target.closest && event.target.closest('a[href]');
    if (!anchor) return;
    const url = anchor.href;
    if (!url || /^(javascript|blob|data):/i.test(url)) return;

    const viaAlt = settings.altClick && event.altKey;
    if (!viaAlt) {
      // The browser's own download interception handles plain file links, so
      // click capture only has to cover what it cannot: magnets, and links the
      // browser would render instead of download.
      if (!settings.capture) return;
      if (!looksDownloadable(settings, url, anchor.hasAttribute('download'), location.href)) return;
      if (settings.intercept && /^https?:/i.test(url) && !anchor.hasAttribute('download')) {
        // Let the browser start it; the download listener takes it from there.
        return;
      }
    } else if (!isFetchable(url)) {
      return;
    }
    // An excluded domain means "leave this site alone", so even alt+click stays
    // the browser's — the context menu is the way to override deliberately.
    if (isBlocked(settings, url, location.href)) return;

    event.preventDefault();
    event.stopPropagation();
    api.runtime.sendMessage({
      type: 'send',
      item: {
        url,
        filename: filenameFromUrl(url, anchor.getAttribute('download')),
        referer: location.href,
        cookie: document.cookie || undefined,
        source: location.hostname,
      },
    });
  }, true);

  /* -------------------------------------------------------- video button */
  /* The button is anchored over the player, but nothing about it reads the
     video element's src — that is a blob: handle to an MSE buffer and cannot be
     downloaded. What can be downloaded is whatever manifest the page fetched,
     which the background worker saw go past on the network. The element is only
     used to decide *where* to put the button and whether one is worth showing. */

  const VIDEO_MIN = () => (settings && settings.videoMinPx) || 200;
  let overlay = null;      // { host, root, button, menu }
  let anchored = null;     // the <video> the button currently sits on
  let candidateCount = 0;
  let frame = 0;

  function buildOverlay() {
    if (overlay) return overlay;
    const host = document.createElement('div');
    // A shadow root so the page's CSS cannot restyle or hide the button, and
    // ours cannot leak into the page.
    const root = host.attachShadow({ mode: 'closed' });
    host.style.cssText = 'position:absolute;z-index:2147483646;pointer-events:none;';
    const style = document.createElement('style');
    style.textContent = `
      :host { all: initial; }
      .wrap { position: relative; font: 500 12px/1.3 system-ui, sans-serif; pointer-events: auto; }
      .btn {
        display: inline-flex; align-items: center; gap: 6px;
        background: rgba(13,15,19,.86); color: #e7eaf0;
        border: 1px solid rgba(255,255,255,.16); border-radius: 8px;
        padding: 6px 10px; cursor: pointer; backdrop-filter: blur(6px);
        box-shadow: 0 4px 14px rgba(0,0,0,.4); opacity: .55;
        transition: opacity .12s ease, background .12s ease;
      }
      .btn:hover, .wrap:hover .btn { opacity: 1; background: rgba(20,24,32,.95); }
      .btn svg { width: 14px; height: 14px; fill: currentColor; }
      .menu {
        position: absolute; top: calc(100% + 6px); right: 0; min-width: 190px;
        background: rgba(13,15,19,.97); color: #e7eaf0;
        border: 1px solid rgba(255,255,255,.14); border-radius: 10px;
        padding: 5px; box-shadow: 0 12px 34px rgba(0,0,0,.55); display: none;
      }
      .menu.open { display: block; }
      .menu.up { top: auto; bottom: calc(100% + 6px); }
      .row {
        display: flex; align-items: center; justify-content: space-between; gap: 12px;
        padding: 7px 9px; border-radius: 6px; cursor: pointer; white-space: nowrap;
      }
      .row:hover { background: rgba(91,157,255,.16); }
      .row .q { font-weight: 600; }
      .row .meta { color: #8b94a6; font-size: 11px; }
      .note { padding: 7px 9px; color: #8b94a6; font-size: 11px; white-space: normal; max-width: 240px; }
      .note.err { color: #ff8f99; }
    `;
    const wrap = document.createElement('div');
    wrap.className = 'wrap';
    const button = document.createElement('button');
    button.className = 'btn';
    button.innerHTML = '<svg viewBox="0 0 24 24"><path d="M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z"/></svg><span>Download</span>';
    const menu = document.createElement('div');
    menu.className = 'menu';
    wrap.append(button, menu);
    root.append(style, wrap);
    (document.body || document.documentElement).append(host);

    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      menu.classList.contains('open') ? closeMenu() : openMenu();
    });
    document.addEventListener('click', (event) => {
      if (!host.contains(event.target)) closeMenu();
    }, true);

    overlay = { host, root, wrap, button, menu };
    return overlay;
  }

  function closeMenu() {
    if (overlay) overlay.menu.classList.remove('open');
  }

  function note(text, isError) {
    const el = document.createElement('div');
    el.className = isError ? 'note err' : 'note';
    el.textContent = text;
    return el;
  }

  async function openMenu() {
    const { menu } = buildOverlay();
    menu.replaceChildren(note('Looking for streams…'));
    menu.classList.add('open');

    const found = await api.runtime.sendMessage({ type: 'videoCandidates' });
    const candidates = (found && found.candidates) || [];
    if (!candidates.length) {
      menu.replaceChildren(note(
        'No stream seen yet for this tab. Start playback and try again — the '
        + 'manifest has to go past before it can be downloaded.'));
      return;
    }

    const probe = await api.runtime.sendMessage({ type: 'videoProbe', candidate: candidates[0] });
    if (!probe || !probe.ok) {
      menu.replaceChildren(note(probe && probe.error ? probe.error : 'Probe failed', true));
      return;
    }
    const result = probe.probe || {};
    const variants = result.variants || [];
    if (!variants.length) {
      menu.replaceChildren(note(result.unsupported || 'Nothing downloadable in that stream', true));
      return;
    }
    if (result.kind !== 'direct' && result.ffmpeg === false) {
      menu.replaceChildren(note(
        'This is a segmented stream and ffmpeg is not installed on the manager, '
        + 'so its parts cannot be joined into a file.', true));
      return;
    }

    menu.replaceChildren();
    for (const variant of variants) {
      const row = document.createElement('div');
      row.className = 'row';
      const quality = document.createElement('span');
      quality.className = 'q';
      quality.textContent = variant.quality;
      const meta = document.createElement('span');
      meta.className = 'meta';
      meta.textContent = [
        variant.bandwidth ? `${Math.round(variant.bandwidth / 1000)} kbps` : '',
        variant.needsAudio ? '+audio' : '',
      ].filter(Boolean).join(' · ');
      row.append(quality, meta);
      row.addEventListener('click', async () => {
        menu.replaceChildren(note(`Sending ${variant.quality} to aria2c manager…`));
        const out = await api.runtime.sendMessage({
          type: 'videoDownload',
          candidate: candidates[0],
          variant,
          title: document.title,
        });
        if (out && out.ok) {
          closeMenu();
        } else {
          menu.replaceChildren(note((out && out.error) || 'Download failed', true));
        }
      });
      menu.append(row);
    }
    if (result.unsupported) menu.append(note(result.unsupported, true));
  }

  function bestVideo() {
    let best = null;
    let bestArea = 0;
    for (const video of document.querySelectorAll('video')) {
      const box = video.getBoundingClientRect();
      if (box.width < VIDEO_MIN() || box.height < VIDEO_MIN() * 0.5) continue;
      // Off-screen players (carousels, hidden tabs) should not claim the button.
      if (box.bottom < 0 || box.top > innerHeight) continue;
      const area = box.width * box.height;
      if (area > bestArea) { bestArea = area; best = video; }
    }
    return best;
  }

  const GAP = 6;

  function position() {
    frame = 0;
    if (!settings || !settings.enabled || settings.videoSniffer === false || !candidateCount) {
      if (overlay) overlay.host.style.display = 'none';
      return;
    }
    const video = bestVideo();
    if (!video) {
      if (overlay) overlay.host.style.display = 'none';
      closeMenu();
      return;
    }
    const { host, wrap, menu } = buildOverlay();
    anchored = video;

    // In fullscreen the video *is* the screen, so there is no outside to sit in
    // — and the page body is not painted, so the button also has to be a child
    // of the fullscreen element or it simply is not there.
    const full = document.fullscreenElement;
    const parent = full && full.contains(video) ? full : (document.body || document.documentElement);
    if (host.parentElement !== parent) parent.append(host);

    // Measure before placing: the button's width depends on the font the page
    // happens to resolve, and a guessed width leaves it hanging off the edge.
    host.style.display = 'block';
    const box = video.getBoundingClientRect();
    const size = wrap.getBoundingClientRect();

    if (full) {
      host.style.position = 'fixed';
      host.style.top = `${box.top + GAP}px`;
      host.style.left = `${Math.max(GAP, box.right - size.width - GAP)}px`;
      menu.classList.remove('up');
      return;
    }

    // Outside the frame, above its top-right corner — the button never covers
    // the picture or the site's own controls. When the player is hard against
    // the top of the viewport there is no room up there, so it goes below the
    // frame instead rather than being pushed off-screen.
    const roomAbove = box.top >= size.height + GAP * 2;
    const top = roomAbove ? box.top - size.height - GAP : box.bottom + GAP;
    const left = Math.max(GAP, Math.min(box.right - size.width, innerWidth - size.width - GAP));

    host.style.position = 'absolute';
    host.style.top = `${top + scrollY}px`;
    host.style.left = `${left + scrollX}px`;

    // The menu drops from the button, so it flips up when the button sits low.
    menu.classList.toggle('up', top > innerHeight - 260);
  }

  function schedule() {
    if (!frame) frame = requestAnimationFrame(position);
  }

  addEventListener('scroll', schedule, { passive: true, capture: true });
  addEventListener('resize', schedule, { passive: true });
  document.addEventListener('fullscreenchange', schedule);
  new MutationObserver(schedule).observe(document.documentElement,
    { childList: true, subtree: true });
  setInterval(schedule, 2000);   // players that resize without mutating the DOM

  /* ----------------------------------------------------------- messages */
  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'videoFound') {
      candidateCount = message.count || 0;
      schedule();
      sendResponse({ ok: true });
      return false;
    }
    if (message.type === 'toast') {
      toast(message.message, message.kind);
      sendResponse({ ok: true });
      return false;
    }
    if (message.type === 'collect') {
      const anchors = [...document.querySelectorAll('a[href]')];
      let picked;
      if (message.scope === 'selection') {
        const selection = window.getSelection();
        picked = (!selection || selection.isCollapsed)
          ? []
          : anchors.filter((a) => selection.getRangeAt(0).intersectsNode(a));
      } else {
        picked = anchors.filter(
          (a) => looksDownloadable(settings, a.href, a.hasAttribute('download'), location.href));
      }
      sendResponse({
        urls: [...new Set(picked.map((a) => a.href).filter(isFetchable))],
        cookie: document.cookie || '',
      });
      return false;
    }
    return false;
  });
})();
