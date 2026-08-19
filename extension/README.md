# aria2c manager — browser extension

Hands the browser's downloads to the local `aria2c-manager` daemon. MV3, and the
same unpacked directory loads in both Firefox and Chromium.

## Load it

* **Firefox** — `about:debugging#/runtime/this-firefox` → *Load Temporary Add-on*
  → pick `manifest.json`. Temporary add-ons are dropped on restart; to keep it,
  sign it (`npx web-ext sign`) or run Developer Edition with
  `xpinstall.signatures.required=false`.
* **Chromium / Chrome** — `chrome://extensions` → *Developer mode* →
  *Load unpacked* → pick this directory.

Then check the server URL in Settings matches `server.port` in `config.yaml`.

## How it works

```
browser starts a download ─→ downloads.onCreated
                              ├─ cancel + erase the browser's copy
                              └─ POST /api/intake/add  (url, cookies, referer, UA)
```

Everything that touches the network lives in `background.js`, because only the
background context can read the cookie store — which is how `HttpOnly` session
cookies reach aria2. The content script only captures clicks, draws toasts and
harvests links for the context menus.

| File | Role |
| --- | --- |
| `manifest.json` | MV3; declares both `background.service_worker` (Chrome) and `background.scripts` (Firefox) |
| `lib/common.js` | settings defaults + storage, the HTTP client, and the "is this a download?" rules — loaded by every surface |
| `background.js` | download interception, context menus, notifications, badge, all manager requests |
| `content.js` | click capture, in-page toasts, link harvesting |
| `popup.html/js` | toolbar popup: live status, quick add, per-site switch |
| `options.html/js` | settings page |
| `ui.css` | shared styling for popup + options |

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
