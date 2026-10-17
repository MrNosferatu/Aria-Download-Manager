"""Render the extension's manager page to a self-contained HTML file.

Captures the live JSON from a running manager over its socket, then emits one
HTML file with the CSS/JS inlined and `ManagerLink` (the native-messaging
connection, which only exists inside the extension) replaced by the captured
fixtures. The result opens offline in any browser, headless ones included.

    python3 tests/render_ui.py --tab downloads --out /tmp/ui.html

Options: --socket PATH (default: the manager's default socket), --tab
downloads|settings|rules|log, --expand to open the first download's detail panel,
--rule N to open the Nth action's editor, --fixtures FILE to lay JSON responses (path -> body) over the captured ones;
a key ending in /* adds its fields to every captured response under it.
tests/ui_fixtures.json holds states the live manager rarely has.
"""

from __future__ import annotations

import argparse
import json
import re
import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from aria_download_manager.native_host import default_socket_path  # noqa: E402

STATIC = ROOT / "extension" / "manager"


def fetch(sock_path: str, path: str):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(10)
            sock.connect(sock_path)
            sock.sendall((json.dumps({"id": 1, "method": "GET", "path": path}) + "\n").encode())
            reply = json.loads(sock.makefile("r", encoding="utf-8").readline())
    except (OSError, ValueError) as exc:
        print(f"  warning: {path} -> {exc}")
        return None
    if reply.get("status") != 200:
        print(f"  warning: {path} -> status {reply.get('status')}")
        return None
    return reply.get("body")


def capture(sock_path: str) -> dict:
    fixtures = {
        "/api/state": fetch(sock_path, "/api/state"),
        "/api/log": fetch(sock_path, "/api/log"),
        "/api/config": fetch(sock_path, "/api/config"),
        "/api/global/options": fetch(sock_path, "/api/global/options"),
        "/api/rules": fetch(sock_path, "/api/rules"),
        "/api/routing": fetch(sock_path, "/api/routing"),
        "/api/folders": fetch(sock_path, "/api/folders"),
    }
    state = fixtures.get("/api/state") or {}
    for download in state.get("downloads", []):
        gid = download["gid"]
        detail = fetch(sock_path, f"/api/download/{gid}")
        if detail:
            fixtures[f"/api/download/{gid}"] = detail
    return fixtures


def build(fixtures: dict, tab: str, expand: bool, rule: int = -1) -> str:
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    design = (STATIC.parent / "lib" / "design.css").read_text(encoding="utf-8")
    css = (STATIC / "style.css").read_text(encoding="utf-8")
    js = (STATIC / "app.js").read_text(encoding="utf-8")
    option_help = (STATIC / "option-help.js").read_text(encoding="utf-8")

    state = fixtures.get("/api/state") or {}
    first_gid = ""
    for download in state.get("downloads", []):
        if download["status"] == "active":
            first_gid = download["gid"]
            break

    stub = f"""
const __FIXTURES = {json.dumps(fixtures)};
window.ManagerLink = {{
  async call(method, path) {{
    const body = __FIXTURES[path.split('?')[0]];
    return {{ status: body != null ? 200 : 404, body }};
  }},
  // Delivered synchronously: a headless browser screenshots on the load event,
  // and a timer would fire after the picture was already taken.
  subscribe(sub) {{
    sub.onFrame('state', __FIXTURES['/api/state']);
    sub.onFrame('backlog', (__FIXTURES['/api/log'] || {{}}).events || []);
    return () => {{}};
  }},
  errorText: (reply) => (reply.body && reply.body.error) || `HTTP ${{reply.status}}`,
}};
"""

    driver = f"""
// Registered after app.js, so it runs after init() on the same event.
document.addEventListener('DOMContentLoaded', () => {{
  const tab = {json.dumps(tab)};
  if (tab && tab !== 'downloads') switchTab(tab);
  if ({json.dumps(bool(expand and first_gid))}) toggleDetail({json.dumps(first_gid)});
  if ({rule} >= 0) setTimeout(() => {{ S.openRule = {rule}; renderRules(); }}, 0);
}});
"""

    lib = STATIC.parent / "lib"
    html = html.replace('<link rel="stylesheet" href="../lib/design.css">', f"<style>\n{design}\n</style>")
    html = html.replace('<link rel="stylesheet" href="../lib/filetree.css">',
                        f"<style>\n{(lib / 'filetree.css').read_text(encoding='utf-8')}\n</style>")
    html = html.replace('<link rel="stylesheet" href="style.css">', f"<style>\n{css}\n</style>")
    # Every page script inlined in order; link.js is the one replaced by the stub.
    inline = {"../lib/link.js": stub, "app.js": js, "option-help.js": option_help}
    for src in re.findall(r'<script src="([^"]+)"></script>', html):
        body = inline.get(src)
        if body is None:
            body = (STATIC / src).resolve().read_text(encoding="utf-8")
        html = html.replace(f'<script src="{src}"></script>', f"<script>\n{body}\n</script>", 1)
    html = html.replace("</body>", f"<script>{driver}</script>\n</body>", 1)
    return html


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=default_socket_path())
    parser.add_argument("--out", default="/tmp/aria-download-manager-ui.html")
    parser.add_argument("--tab", default="downloads",
                        choices=["downloads", "settings", "rules", "log"])
    parser.add_argument("--expand", action="store_true",
                        help="open the first active download's detail panel")
    parser.add_argument("--rule", type=int, default=-1,
                        help="open the Nth action's editor (with --tab rules)")
    parser.add_argument("--fixtures", action="append", default=[],
                        help="a JSON file of {path: body} laid over the captured responses")
    args = parser.parse_args()

    print(f"capturing from {args.socket}")
    fixtures = capture(args.socket)
    for extra in args.fixtures:
        for path, body in json.loads(Path(extra).read_text(encoding="utf-8")).items():
            # "/api/download/*" adds its fields to every captured detail.
            if path.endswith("/*"):
                for key in [k for k in fixtures if k.startswith(path[:-1])]:
                    fixtures[key] = {**(fixtures[key] or {}), **body}
            else:
                fixtures[path] = body
    if not fixtures.get("/api/state"):
        print("error: could not read /api/state — is the manager running?")
        return 1
    out = Path(args.out)
    out.write_text(build(fixtures, args.tab, args.expand, args.rule), encoding="utf-8")
    downloads = len((fixtures["/api/state"] or {}).get("downloads", []))
    print(f"wrote {out} ({out.stat().st_size} bytes, {downloads} download(s), tab={args.tab})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
