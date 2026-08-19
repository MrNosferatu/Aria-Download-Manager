# AMO submission notes

Everything addons.mozilla.org asks for, ready to paste. Submit at
<https://addons.mozilla.org/developers/addon/submit/distribution> — a free
account is all it takes; there is no fee for Firefox.

Upload `dist/aria2c_manager_download_catcher-<version>.zip` (`./build.sh build`).

---

**Name**

aria2c manager — download catcher

**Summary** (250 char limit)

Hands the browser's downloads to a local aria2c-manager daemon: multi-connection
downloading, a real queue, retries and stall recovery. Sends the page's cookies,
referer and user-agent, so login-protected files keep working.

**Description**

This extension is the browser half of aria2c-manager, a small self-hosted
download server built on aria2c. It does not download anything by itself and
sends nothing to the internet — it talks only to the address you set in its
settings, which defaults to http://127.0.0.1:6810 on your own machine.

You need the daemon running first: https://github.com/FHADWA/Aria2C

What it does:

• Takes over the browser's own downloads. Anything Firefox starts to download is
  cancelled, removed from the download list, and queued in aria2c instead — with
  the page's cookies, referer and user-agent attached, so files behind a login
  still work.
• Toolbar popup with live speed, active and queued counts, per-download
  progress, and a box to paste a URL or magnet link.
• Right-click a link, image, video, audio file, page or text selection to send it.
• Click capture for magnet links and for files the browser would open in a
  viewer instead of downloading. Alt+click sends any link.
• Filters: minimum file size, which extensions count, and a per-site blocklist.

blob: and data: downloads are left to the browser, since aria2 cannot fetch them.

**Category** — Download Management
**License** — MIT
**Privacy policy** — see below
**Support site** — the GitHub repository above

---

## Permission justifications

Reviewers ask about each of these. Short answers:

| Permission | Why |
| --- | --- |
| `downloads` | The entire point: `downloads.onCreated` is how a browser download is detected, then `cancel`/`erase` hand it to aria2c rather than downloading it twice. |
| `cookies` | A download URL is often only valid for the session that produced it. The cookie header is read for the download's own URL and forwarded to the daemon, which passes it to aria2. It covers `HttpOnly` cookies, which `document.cookie` cannot see. |
| `<all_urls>` | Downloads start from arbitrary sites, so the content script (click capture) and the cookie lookup cannot be restricted to a fixed list. The host permission is also what allows requests to the user's own daemon address, which is configurable. |
| `contextMenus` | The right-click entries. |
| `notifications` | Reports "queued" / "failed" when no page is in focus to show a toast in. |
| `storage` | Settings only, stored locally. |
| `alarms` | A 30-second tick that refreshes the toolbar badge count. |
| `tabs` | Reads the active tab's URL for the popup's per-site switch, and delivers toasts to the tab an action came from. |

## Privacy policy

This extension collects nothing, stores nothing remotely, and contains no
analytics, telemetry or third-party code.

It sends download URLs, and the cookies/referer/user-agent belonging to those
URLs, to one destination only: the server address configured in its settings,
which defaults to `http://127.0.0.1:6810` — the user's own machine. That address
is the aria2c-manager daemon the user runs themselves. No other network requests
are made.

Settings are kept in the browser's local extension storage and never leave the
browser.

## Source code

Not minified, not bundled, no build step: the uploaded package is the source.
