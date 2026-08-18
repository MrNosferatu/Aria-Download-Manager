"""Two fake file-hosting sites for testing the hoster queue.

  /direct/<name>      a MediaFire-shaped page: the direct link sits in an
                      <a id="downloadButton"> exactly as the real site does
                      (markup copied from a live page in August 2026)
  /xfs/<name>         an XFileSharing-shaped flow: op=download1 -> countdown +
                      challenge -> op=download2 -> direct link
  /files/<name>       the "file" itself

Query flags on /xfs/<name>:
  ?challenge=none     no challenge, just the countdown
  ?challenge=digits   the ordered-digits challenge (readable from the markup)
  ?challenge=code     an image captcha; the answer is `expected_code`
  ?challenge=browser  reCAPTCHA markup, i.e. a browser-only challenge
  ?challenge=turnstile  Cloudflare Turnstile markup (the checkbox kind)
  ?cf=1               serve a Cloudflare interstitial unless a cf_clearance
                      cookie is presented, like a host behind Cloudflare
  ?wait=N             countdown seconds (default 1)

Run standalone:  python3 tests/fake_hoster.py --port 8770
"""

from __future__ import annotations

import argparse
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

EXPECTED_CODE = "4821"
CF_CLEARANCE = "cf-clearance-token-xyz"

CLOUDFLARE_INTERSTITIAL = """<!doctype html><html><head>
  <title>Just a moment...</title></head><body>
  <div class="cf-browser-verification cf-im-under-attack"></div>
  <p>Checking if the site connection is secure</p>
  <script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>
  </body></html>"""
FILE_SIZE = 6 * 1024 * 1024  # small enough that the fake aria2 finishes fast


class HosterState:
    def __init__(self) -> None:
        self.step1_hits = 0
        self.step2_hits = 0
        self.bad_codes = 0
        self.cf_blocks = 0
        self.step2_times: list[float] = []


def mediafire_page(host: str, name: str) -> str:
    """Mirrors the real MediaFire button: href before id, attributes on separate lines."""
    return f"""<!doctype html><html><head><title>{name}</title></head><body>
      <div class="dl-info"><div class="filename">{name}</div></div>
      <a class="input popsok"
           aria-label="Download file"
           href="http://{host}/files/{name}"           id="downloadButton"
           rel="nofollow">Download ({FILE_SIZE // 1048576} MB)</a>
    </body></html>"""


def xfs_step1_page(name: str, query: str) -> str:
    return f"""<!doctype html><html><body>
      <h1>Download {name}</h1>
      <form name="F1" method="POST" action="">
        <input type="hidden" name="op" value="download1">
        <input type="hidden" name="usr_login" value="">
        <input type="hidden" name="id" value="abc123{name}">
        <input type="hidden" name="fname" value="{name}">
        <input type="hidden" name="referer" value="">
        <input type="submit" name="method_free" value="Free Download">
      </form><!-- {query} --></body></html>"""


def xfs_wait_page(name: str, wait: int, challenge: str) -> str:
    extra = ""
    if challenge == "digits":
        # Digits as plain text, ordered by a CSS offset — the classic variant.
        # Sorted by offset these spell EXPECTED_CODE.
        offsets = [(63, "2"), (18, "4"), (95, "1"), (41, "8")]
        spans = "".join(
            f'<span style="position:absolute;padding-left:{off}px;padding-top:8px;">{d}</span>'
            for off, d in offsets
        )
        extra = f'<div id="challenge">{spans}</div><input type="text" name="code" autocomplete="off">'
    elif challenge == "code":
        extra = (
            '<img src="/captchas/abc.jpg" alt="captcha">'
            '<input type="text" name="code" autocomplete="off">'
        )
    elif challenge == "turnstile":
        extra = (
            '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>'
            '<div class="cf-turnstile" data-sitekey="0x4FAKE"></div>'
            '<input type="hidden" name="cf-turnstile-response" value="">'
        )
    elif challenge == "browser":
        extra = (
            '<script src="https://www.google.com/recaptcha/api.js"></script>'
            '<div class="g-recaptcha" data-sitekey="6Lc-FAKE-SITEKEY"></div>'
        )
    return f"""<!doctype html><html><body>
      <span id="countdown_str">Wait <span id="xyz" class="seconds">{wait}</span> seconds</span>
      <form name="F1" method="POST" action="">
        <input type="hidden" name="op" value="download2">
        <input type="hidden" name="id" value="abc123{name}">
        <input type="hidden" name="rand" value="r4nd0m{name}">
        <input type="hidden" name="referer" value="">
        <input type="hidden" name="down_script" value="1">
        {extra}
        <input type="submit" value="Create Download Link">
      </form></body></html>"""


def xfs_link_page(host: str, name: str) -> str:
    return f"""<!doctype html><html><body>
      <a id="direct_link" class="btn btn-dow" href="http://{host}/files/{name}">Download</a>
      </body></html>"""


def make_handler(state: HosterState):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        # ---- helpers
        def _send(self, body: bytes, content_type: str = "text/html; charset=utf-8",
                  status: int = 200, extra: dict | None = None):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        @property
        def host_header(self) -> str:
            return self.headers.get("Host", "127.0.0.1")

        def cloudflare_blocks(self, query: dict) -> bool:
            """True when ?cf=1 and the request lacks the clearance cookie."""
            if (query.get("cf") or ["0"])[0] != "1":
                return False
            cookies = self.headers.get("Cookie", "")
            return f"cf_clearance={CF_CLEARANCE}" not in cookies

        def send_interstitial(self):
            state.cf_blocks += 1
            self._send(CLOUDFLARE_INTERSTITIAL.encode(), status=503)

        # ---- routes
        def do_GET(self):
            parsed = urlparse(self.path)
            parts = [p for p in parsed.path.split("/") if p]

            if parts[:1] == ["files"]:
                name = parts[1] if len(parts) > 1 else "file.bin"
                self._send(
                    b"\0" * FILE_SIZE, "application/octet-stream",
                    extra={"Content-Disposition": f'attachment; filename="{name}"'},
                )
                return

            if parts[:1] == ["direct"]:
                if self.cloudflare_blocks(parse_qs(parsed.query)):
                    self.send_interstitial()
                    return
                name = parts[1] if len(parts) > 1 else "file.bin"
                self._send(mediafire_page(self.host_header, name).encode())
                return

            if parts[:1] == ["xfs"]:
                if self.cloudflare_blocks(parse_qs(parsed.query)):
                    self.send_interstitial()
                    return
                name = parts[1] if len(parts) > 1 else "file.bin"
                self._send(xfs_step1_page(name, parsed.query).encode())
                return

            if parts[:1] == ["captchas"]:
                # 1x1 gif, enough for the UI to render something
                self._send(
                    b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!"
                    b"\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01"
                    b"\x00\x00\x02\x02D\x01\x00;",
                    "image/gif",
                )
                return

            if parsed.path == "/dead":
                self._send(b"<html><body>File not found</body></html>", status=404)
                return

            self._send(b"<html><body>fake hoster</body></html>")

        do_HEAD = do_GET

        def do_POST(self):
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            challenge = (query.get("challenge") or ["none"])[0]
            wait = int((query.get("wait") or ["1"])[0])
            parts = [p for p in parsed.path.split("/") if p]
            name = parts[1] if len(parts) > 1 else "file.bin"

            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8", "replace")
            fields = {k: v[0] for k, v in parse_qs(body).items()}
            op = fields.get("op", "")

            if op == "download1":
                state.step1_hits += 1
                self._send(xfs_wait_page(name, wait, challenge).encode())
                return

            if op == "download2":
                state.step2_hits += 1
                state.step2_times.append(time.time())
                if challenge in ("digits", "code"):
                    if fields.get("code") != EXPECTED_CODE:
                        state.bad_codes += 1
                        self._send(
                            b'<html><body><div class="err">Wrong captcha</div></body></html>'
                        )
                        return
                self._send(xfs_link_page(self.host_header, name).encode())
                return

            self._send(b'<html><body><div class="err">Unknown op</div></body></html>')

    return Handler


def serve(port: int = 0) -> tuple[ThreadingHTTPServer, HosterState, int]:
    state = HosterState()
    httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(state))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, state, httpd.server_address[1]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fake file hosts for testing")
    parser.add_argument("--port", type=int, default=8770)
    args = parser.parse_args()
    httpd, state, port = serve(args.port)
    print(f"fake hoster on http://127.0.0.1:{port}")
    print(f"  mediafire-style : http://127.0.0.1:{port}/direct/movie.mkv")
    print(f"  xfilesharing    : http://127.0.0.1:{port}/xfs/archive.zip?challenge=digits&wait=2")
    print(f"  turnstile       : http://127.0.0.1:{port}/xfs/movie.mkv?challenge=turnstile")
    print(f"  behind cloudflare: http://127.0.0.1:{port}/xfs/gated.zip?cf=1")
    print(f"  captcha code    : {EXPECTED_CODE}")
    print(f"  cf_clearance    : {CF_CLEARANCE}")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        httpd.shutdown()
