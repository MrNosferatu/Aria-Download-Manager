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
  /* The DankBar feedback pill, on the page: an icon, one line, at most one
     button. Drawn in a closed shadow root so the page's CSS cannot reach it,
     and the inverse of the page's colour scheme so it reads on any site.
     Hovering holds it; an error stays until it is dismissed. */
  let toastRoot = null;

  const TOAST_CSS = `
    :host { all: initial; }
    .stack { position: fixed; right: 16px; bottom: 16px; z-index: 2147483647;
      display: flex; flex-direction: column; align-items: flex-end; gap: 8px; pointer-events: none;
      font: 500 13px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif; }
    .t { pointer-events: auto; display: flex; align-items: center; gap: 10px; max-width: 420px;
      padding: 8px 8px 8px 14px; border-radius: 999px;
      box-shadow: 0 2px 6px rgba(0,0,0,.18), 0 8px 24px rgba(0,0,0,.22);
      background: oklch(24% 0.012 260); color: oklch(93% 0.008 260);
      animation: rise .22s cubic-bezier(.2,0,0,1); }
    .t.err { background: oklch(31% 0.10 20); color: oklch(92% 0.04 20); }
    .t svg { width: 18px; height: 18px; flex: none; fill: oklch(78% 0.14 155); }
    .t.err svg { fill: oklch(76% 0.14 20); }
    .t .m { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .t button { all: unset; cursor: pointer; flex: none; height: 30px; padding: 0 12px; border-radius: 15px;
      font-weight: 600; font-size: 12px; background: oklch(80% 0.12 255); color: oklch(24% 0.09 255); }
    .t.err button { background: oklch(92% 0.04 20); color: oklch(31% 0.10 20); }
    .t button.x { padding: 0; width: 30px; text-align: center; background: transparent; color: inherit; font-size: 16px; }
    .t button:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
    @media (prefers-color-scheme: dark) {
      .t { background: oklch(93% 0.008 260); color: oklch(22% 0.015 260); }
      .t svg { fill: oklch(52% 0.15 155); }
      .t button { background: oklch(50% 0.17 255); color: oklch(99% 0 0); }
    }
    @keyframes rise { from { transform: translateY(12px); opacity: 0; } }
    @media (prefers-reduced-motion: reduce) { .t { animation: none; } }
  `;
  const OK_ICON = '<svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-2 15-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>';
  const ERR_ICON = '<svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>';

  function toastStack() {
    if (toastRoot) return toastRoot;
    const host = document.createElement('div');
    const root = host.attachShadow({ mode: 'closed' });
    const style = document.createElement('style');
    style.textContent = TOAST_CSS;
    const stack = document.createElement('div');
    stack.className = 'stack';
    root.append(style, stack);
    (document.body || document.documentElement).append(host);
    toastRoot = stack;
    return stack;
  }

  function toast(message, kind, action) {
    if (!settings || !settings.pageToasts) return;
    const isError = kind === 'error';
    const el = document.createElement('div');
    el.className = `t${isError ? ' err' : ''}`;
    el.setAttribute('role', isError ? 'alert' : 'status');
    el.innerHTML = isError ? ERR_ICON : OK_ICON;
    const text = document.createElement('span');
    text.className = 'm';
    // A download name is remote text: set as text, never as HTML.
    text.textContent = message;
    text.title = message;
    el.append(text);

    let timer = null;
    const close = () => { clearTimeout(timer); el.remove(); };
    const arm = () => { if (!isError) timer = setTimeout(close, 5000); };
    if (action && action.label) {
      const button = document.createElement('button');
      button.textContent = action.label;
      button.addEventListener('click', () => {
        close();
        api.runtime.sendMessage({ type: 'toastAction', kind: action.kind, url: action.url || '' }).catch(() => {});
      });
      el.append(button);
    }
    if (isError) {
      const x = document.createElement('button');
      x.className = 'x';
      x.textContent = '×';
      x.setAttribute('aria-label', 'Dismiss');
      x.addEventListener('click', close);
      el.append(x);
    }
    el.addEventListener('mouseenter', () => clearTimeout(timer));
    el.addEventListener('mouseleave', arm);
    toastStack().append(el);
    arm();
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
      // Magnets follow their own switch, not the general click-capture one.
      if (!settings.capture && !isMagnet(url)) return;
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
  let candidates = [];     // [{url, kind}] the background worker saw on this tab
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
        background: oklch(24% 0.012 260 / .88); color: oklch(93% 0.008 260);
        border: 0; border-radius: 999px;
        padding: 7px 12px 7px 10px; cursor: pointer; backdrop-filter: blur(8px);
        box-shadow: 0 2px 6px rgba(0,0,0,.25), 0 6px 18px rgba(0,0,0,.3); opacity: .85;
        transition: opacity .12s ease, background .12s ease;
      }
      .btn:hover, .wrap:hover .btn { opacity: 1; background: oklch(36% 0.11 255 / .96); }
      .btn svg { width: 16px; height: 16px; fill: currentColor; }
      .menu {
        position: absolute; top: calc(100% + 6px); right: 0; min-width: 200px;
        background: oklch(24% 0.012 260 / .98); color: oklch(93% 0.008 260);
        border-radius: 12px; padding: 6px;
        box-shadow: 0 6px 16px rgba(0,0,0,.26), 0 20px 48px rgba(0,0,0,.3); display: none;
      }
      .menu.open { display: block; }
      .menu.up { top: auto; bottom: calc(100% + 6px); }
      .row {
        all: unset; box-sizing: border-box; width: 100%;
        display: flex; align-items: center; justify-content: space-between; gap: 12px;
        padding: 8px 10px; border-radius: 8px; cursor: pointer; white-space: nowrap;
      }
      .row:hover, .row:focus-visible { background: oklch(80% 0.12 255 / .16); }
      .btn:focus-visible { outline: 2px solid oklch(80% 0.12 255); outline-offset: 2px; opacity: 1; }
      .row .q { font-weight: 600; }
      .row .meta { color: oklch(72% 0.014 260); font-size: 11px; }
      .note { padding: 8px 10px; color: oklch(72% 0.014 260); font-size: 11px; white-space: normal; max-width: 240px; }
      .note.err { color: oklch(80% 0.10 20); }
    `;
    const wrap = document.createElement('div');
    wrap.className = 'wrap';
    const button = document.createElement('button');
    button.className = 'btn';
    button.innerHTML = '<svg viewBox="0 0 24 24"><path d="M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z"/></svg><span>Download video</span>';
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
    menu.replaceChildren(note('Looking for the stream…'));
    menu.classList.add('open');

    const found = await api.runtime.sendMessage({ type: 'videoCandidates' });
    const candidates = (found && found.candidates) || [];
    // A player with a real file as its source is playing exactly that file, so
    // it goes first rather than whichever manifest the page fetched last.
    const own = anchored && sourceOf(anchored);
    const mine = own && candidates.findIndex((c) => sameUrl(c.url, own));
    if (mine > 0) candidates.unshift(...candidates.splice(mine, 1));
    if (!candidates.length) {
      menu.replaceChildren(note(
        'No stream seen on this tab yet. Start playback, then try again.'));
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
      menu.replaceChildren(note(result.unsupported || 'Nothing in that stream can be downloaded', true));
      return;
    }
    if (result.kind !== 'direct' && result.ffmpeg === false) {
      menu.replaceChildren(note(
        'This stream comes in segments, and ffmpeg is not installed where the manager runs, '
        + 'so they cannot be joined into one file.', true));
      return;
    }

    // Say how many before the next click, not after it.
    const label = overlay && overlay.button.querySelector('span');
    if (label) label.textContent = `Video · ${variants.length} ${variants.length === 1 ? 'quality' : 'qualities'}`;
    menu.replaceChildren();
    for (const variant of variants) {
      // Buttons, so Tab and Enter reach them as well as the pointer.
      const row = document.createElement('button');
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
        menu.replaceChildren(note(`Adding ${variant.quality}…`));
        const out = await api.runtime.sendMessage({
          type: 'videoDownload',
          candidate: candidates[0],
          variant,
          title: document.title,
        });
        if (out && out.ok) {
          closeMenu();
        } else {
          menu.replaceChildren(note((out && out.error) || 'Could not add it', true));
        }
      });
      menu.append(row);
    }
    if (result.unsupported) menu.append(note(result.unsupported, true));
  }

  const sameUrl = (a, b) => a.split('#')[0] === b.split('#')[0];

  function sourceOf(video) {
    const src = video.currentSrc || video.src || '';
    return /^https?:/i.test(src) ? src : '';
  }

  /* Whether this element is plausibly playing something that was sniffed. A
     <video> with a plain http(s) source names its file outright, so it only
     counts when that very file went past on the network and was big enough to
     be kept — which rules out spinners and looping decorations (Discord's
     loading animation is one) that would otherwise borrow a stream seen
     elsewhere on the page. A blob: source is MSE and says nothing, so any
     sniffed stream will do. No source at all is a player not yet started. */
  function isCandidateVideo(video) {
    const src = sourceOf(video);
    if (src) return candidates.some((c) => sameUrl(c.url, src));
    return /^blob:/i.test(video.currentSrc || video.src || '');
  }

  function bestVideo() {
    let best = null;
    let bestArea = 0;
    for (const video of document.querySelectorAll('video')) {
      if (!isCandidateVideo(video)) continue;
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
    if (!settings || !settings.enabled || settings.videoSniffer === false || !candidates.length) {
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
      candidates = message.candidates || [];
      schedule();
      sendResponse({ ok: true });
      return false;
    }
    if (message.type === 'toast') {
      toast(message.message, message.kind, message.action);
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
      sendResponse({ urls: [...new Set(picked.map((a) => a.href).filter(isFetchable))] });
      return false;
    }
    return false;
  });
})();
