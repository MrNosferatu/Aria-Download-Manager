"""Render the web UI to a self-contained HTML file for visual inspection.

Captures the live JSON from a running manager, then emits one HTML file with the
CSS/JS inlined and `fetch`/`EventSource` stubbed out by the captured fixtures.
The result opens offline and renders exactly what the real UI would, which makes
it screenshot-able by headless browsers (a live SSE stream keeps a real page in
a permanent "loading" state, so headless screenshots never fire).

    python3 tests/render_ui.py --base http://127.0.0.1:6810 --tab downloads \
        --out /tmp/ui.html

Options: --tab downloads|settings|hosters|rules|log|help, --expand to open the first
download's detail panel.
"""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from pathlib import Path

STATIC = Path(__file__).resolve().parent.parent / "aria2c_manager" / "static"


def fetch(base: str, path: str):
    try:
        with urllib.request.urlopen(base.rstrip("/") + path, timeout=10) as res:
            return json.load(res)
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
        print(f"  warning: {path} -> {exc}")
        return None


def capture(base: str) -> dict:
    fixtures = {
        "/api/state": fetch(base, "/api/state"),
        "/api/log": fetch(base, "/api/log"),
        "/api/config": fetch(base, "/api/config"),
        "/api/global/options": fetch(base, "/api/global/options"),
        "/api/rules": fetch(base, "/api/rules"),
        "/api/ping": fetch(base, "/api/ping"),
    }
    state = fixtures.get("/api/state") or {}
    for download in state.get("downloads", []):
        gid = download["gid"]
        detail = fetch(base, f"/api/download/{gid}")
        if detail:
            fixtures[f"/api/download/{gid}"] = detail
    return fixtures


def build(fixtures: dict, tab: str, expand: bool) -> str:
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    css = (STATIC / "style.css").read_text(encoding="utf-8")
    js = (STATIC / "app.js").read_text(encoding="utf-8")

    state = fixtures.get("/api/state") or {}
    first_gid = ""
    for download in state.get("downloads", []):
        if download["status"] == "active":
            first_gid = download["gid"]
            break

    stub = f"""
const __FIXTURES = {json.dumps(fixtures)};
window.fetch = async (url, opts = {{}}) => {{
  const path = String(url).replace(/^https?:\\/\\/[^/]+/, '').split('?')[0];
  const body = __FIXTURES[path];
  return {{
    ok: body != null, status: body != null ? 200 : 404,
    statusText: body != null ? 'OK' : 'Not Found',
    headers: {{ get: () => 'application/json' }},
    json: async () => body, text: async () => JSON.stringify(body),
  }};
}};
window.EventSource = class {{
  constructor() {{ this._handlers = {{}}; setTimeout(() => this._fire(), 30); }}
  addEventListener(type, fn) {{ (this._handlers[type] ||= []).push(fn); }}
  _fire() {{
    const emit = (type, data) => (this._handlers[type] || [])
      .forEach((fn) => fn({{ data: JSON.stringify(data) }}));
    emit('state', __FIXTURES['/api/state']);
    emit('backlog', (__FIXTURES['/api/log'] || {{}}).events || []);
  }}
}};
"""

    driver = f"""
window.addEventListener('load', () => setTimeout(() => {{
  const tab = {json.dumps(tab)};
  if (tab && tab !== 'downloads') switchTab(tab);
  if ({json.dumps(bool(expand and first_gid))}) toggleDetail({json.dumps(first_gid)});
}}, 120));
"""

    html = html.replace('<link rel="stylesheet" href="/static/style.css">', f"<style>\n{css}\n</style>")
    html = html.replace(
        '<script src="/static/app.js"></script>',
        f"<script>{stub}</script>\n<script>\n{js}\n</script>\n<script>{driver}</script>",
    )
    return html


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:6810")
    parser.add_argument("--out", default="/tmp/aria2c-manager-ui.html")
    parser.add_argument("--tab", default="downloads",
                        choices=["downloads", "settings", "hosters", "rules", "log", "help"])
    parser.add_argument("--expand", action="store_true",
                        help="open the first active download's detail panel")
    args = parser.parse_args()

    print(f"capturing from {args.base}")
    fixtures = capture(args.base)
    if not fixtures.get("/api/state"):
        print("error: could not read /api/state — is the manager running?")
        return 1
    out = Path(args.out)
    out.write_text(build(fixtures, args.tab, args.expand), encoding="utf-8")
    downloads = len((fixtures["/api/state"] or {}).get("downloads", []))
    print(f"wrote {out} ({out.stat().st_size} bytes, {downloads} download(s), tab={args.tab})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
