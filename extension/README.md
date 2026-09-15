# Aria Download Manager — browser extension

Hands the browser's downloads to the local Aria Download Manager daemon. MV3, and the
same unpacked directory loads in both Firefox and Chromium.

## Video downloads

The extension watches each tab's traffic for HLS/DASH manifests and media files
(`webRequest`, observation only — MV3 has no blocking form and none is needed).
When it sees one, a small **Download video** button appears over the player; clicking
it asks the manager to read the manifest and lists the qualities the site
offers.

It deliberately does not read `video.src`: a player using Media Source
Extensions puts a `blob:` handle there, pointing at a buffer in memory that
cannot be fetched. The manifest on the network is the real thing.

Cookies come from the `cookies` API rather than `document.cookie`, so HttpOnly
session cookies travel with the probe — without them a members-only stream
probes as an error page with no qualities in it.

Segmented streams need ffmpeg installed where the manager runs; a progressive
`.mp4` does not. DRM-protected video (Widevine) cannot be downloaded by anything.

## Load it

* **Firefox** — `about:debugging#/runtime/this-firefox` → *Load Temporary Add-on*
  → pick `manifest.json`. Temporary add-ons are dropped on restart; to keep it,
  sign it (`npx web-ext sign`) or run Developer Edition with
  `xpinstall.signatures.required=false`.
* **Chromium / Chrome** — `chrome://extensions` → *Developer mode* →
  *Load unpacked* → pick this directory.

Then register the native-messaging host once and restart the browser:

```sh
python3 -m aria_download_manager --install-native-host
```

The settings page checks the connection on its own when it opens; *Test connection* runs it again.

## How it works

```
browser starts a download ─→ downloads.onCreated
                              ├─ cancel + erase the browser's copy
                              └─ POST /api/intake/add  (url, cookies, referer, UA)
                                   │
                                   └─ runtime.connectNative("aria_download_manager")
                                        └─ native_host.py ─→ $XDG_RUNTIME_DIR/aria-download-manager.sock
```

Requests go through native messaging rather than `fetch()` to `127.0.0.1`,
because a VPN or proxy built into the browser can route loopback traffic away
and leave the manager unreachable. A native host is a local process with pipes
and never touches the network. One port serves every request and closes after
20 s idle. Replies over Chrome's 1 MiB host-message limit arrive split into
parts, and `lib/link.js` joins them back together. The manager has no network
port, so there is nothing else to fall back to: a browser that cannot run the
host (Flatpak, Snap) cannot use the extension.

Download handoff lives in `background.js`, because only the background context
can read the cookie store — which is how `HttpOnly` session cookies reach aria2.
The manager page (`manager/`) talks to the manager directly through the same
`lib/link.js`. The content script never contacts the manager: it only captures
clicks, draws toasts and harvests links for the context menus.

| File | Role |
| --- | --- |
| `manifest.json` | MV3; declares both `background.service_worker` (Chrome) and `background.scripts` (Firefox) |
| `lib/common.js` | settings defaults + storage, `request()` for the background, and the "is this a download?" rules — loaded by every surface |
| `background.js` | download interception, context menus, notifications, badge, all manager requests |
| `content.js` | click capture, in-page toasts, link harvesting |
| `lib/link.js` | the connection to the manager over native messaging (requests and the live event stream); shared by the background and the manager page |
| `lib/design.css` | the design system every page shares: Material 3 tonal surfaces in OKLCH, `light-dark()` for both colour schemes, and the controls (switch, chips, segmented Simple/Advanced, cards). The DankBar widget draws the same language with the shell's own widgets |
| `manager/` | the full manager UI, opened from the popup |
| `popup.html/js` | toolbar popup: live status, quick add, per-site switch, opens the full manager |
| `options.html/js` | settings page |
| `ui.css` | layout for the popup and the settings page (controls come from `lib/design.css`) |

## Notes

`web-ext lint` reports two warnings on purpose:

* `BACKGROUND_SERVICE_WORKER_IGNORED` — Firefox ignores the `service_worker` key
  and uses `scripts`; Chrome does the opposite. Both are declared so one
  directory serves both browsers.
* `MISSING_DATA_COLLECTION_PERMISSIONS` — an addons.mozilla.org submission
  requirement. Adding it would pin the extension to Firefox 140+, which is not
  worth it for an add-on loaded from a checkout. (For the record: this extension
  collects nothing and talks only to the URL in its settings.)

`blob:` and `data:` downloads are deliberately left to the browser — aria2 cannot
fetch them.
