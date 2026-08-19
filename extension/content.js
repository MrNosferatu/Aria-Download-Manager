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
    if (!settings) return;
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
      if (!looksDownloadable(settings, url, anchor.hasAttribute('download'))) return;
      if (settings.intercept && /^https?:/i.test(url) && !anchor.hasAttribute('download')) {
        // Let the browser start it; the download listener takes it from there.
        return;
      }
    } else if (!isFetchable(url)) {
      return;
    }

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

  /* ----------------------------------------------------------- messages */
  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
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
        picked = anchors.filter((a) => looksDownloadable(settings, a.href, a.hasAttribute('download')));
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
