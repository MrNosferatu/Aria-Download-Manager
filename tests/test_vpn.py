"""The download-only VPN (vpn.py): choosing, wireproxy's config, running it
(against a fake wireproxy), and routing downloads through the API against the
fake aria2.

    python3 tests/test_vpn.py
"""

from __future__ import annotations

import asyncio
import base64
import os
import stat
import sys
import tempfile
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ["XDG_DATA_HOME"] = tempfile.mkdtemp(prefix="aria-download-manager-test-data-")

from aria_download_manager import vpn as vpn_mod  # noqa: E402
from aria_download_manager.api import create_app  # noqa: E402
from aria_download_manager.config import DEFAULTS, Config  # noqa: E402

DEFAULTS["torrent"]["engine"] = "aria2"
from tests.fake_aria2 import serve  # noqa: E402
from tests.harness import IPCSession, ManagerRunner, check, free_port, summary, wait_for  # noqa: E402

PROTON = """[Interface]
# Key for test
PrivateKey = c2VjcmV0LWtleS1mb3ItdGVzdHMtb25seS0wMDAwMDA=
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = cHVibGljLWtleS1mb3ItdGVzdHMtb25seS0wMDAwMDA=
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.7:51820
"""

#: Answers /readyz on the -i address (503 while $FAKE_WG_DOWN exists) and
#: logs its argv, which is all the manager asks of wireproxy.
FAKE_WIREPROXY = r'''#!/usr/bin/env python3
import http.server, os, sys
args = sys.argv[1:]
open(os.environ["FAKE_WG_LOG"], "a").write(" ".join(args) + "\n")
host, port = args[args.index("-i") + 1].rsplit(":", 1)
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        down = os.path.exists(os.environ["FAKE_WG_DOWN"])
        self.send_response(503 if down else 200); self.end_headers(); self.wfile.write(b"{}")
http.server.HTTPServer((host, int(port)), H).serve_forever()
'''


class Cfg:
    """Just enough of Config for Vpn."""

    def __init__(self, vpn: dict):
        self.data = {"vpn": vpn}
        self._user = {}

    def get(self, dotted, default=None):
        node = self.data
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    def save(self):
        pass


def test_choosing() -> None:
    print("\nchoosing")
    check("sites are kept as bare hosts",
          [vpn_mod.site_of(s) for s in ["https://www.MediaFire.com/file/x", "*.example.org", "host.net:8080/p"]]
          == ["mediafire.com", "example.org", "host.net"])
    sites = ["mediafire.com"]
    check("a listed site and its subdomains match, a look-alike does not",
          vpn_mod.on_list("https://download123.mediafire.com/a.zip", sites)
          and vpn_mod.on_list("https://mediafire.com/a.zip", sites)
          and not vpn_mod.on_list("https://notmediafire.com/a.zip", sites))

    vpn = vpn_mod.Vpn(Cfg({"enabled": False, "sites": sites, "port": 25345}), Path("/tmp"))
    check("with the master switch off nothing uses it, not even a download set to",
          not vpn.wants("https://mediafire.com/a", "auto") and not vpn.wants("https://x.org/a", "on"))
    vpn.cfg.data["vpn"]["enabled"] = True
    check("on: a listed site uses it, others go direct",
          vpn.wants("https://mediafire.com/a") and not vpn.wants("https://x.org/a"))
    check("a download's own choice wins over the list both ways",
          vpn.wants("https://x.org/a", "on") and not vpn.wants("https://mediafire.com/a", "off"))
    routed = vpn.route(["https://mediafire.com/a"], {"dir": "/d", "vpn": "auto"})
    check("route sets all-proxy and takes the choice out of aria2's options",
          routed == {"dir": "/d", "all-proxy": "http://127.0.0.1:25345"}, str(routed))
    check("a direct download keeps no proxy", vpn.route(["https://x.org/a"], {"vpn": "auto"}) == {})
    own = {"all-proxy": "http://10.0.0.9:3128"}
    check("a proxy typed in for the download wins over the site list",
          vpn.route(["https://mediafire.com/a"], dict(own)) == own)
    check("but an explicit VPN choice replaces it",
          vpn.route(["https://x.org/a"], {**own, "vpn": "on"})["all-proxy"] == "http://127.0.0.1:25345")
    check("carries() reads aria2's own spelling back",
          vpn.carries({"all-proxy": "http://127.0.0.1:25345/"}) and not vpn.carries({"all-proxy": ""}))


def test_shared_js() -> None:
    """The front-ends' copy of the site matching: identical in both, and
    deciding every case the way the manager does."""
    print("\nthe front-ends' site matching (lib/vpn-core.js)")
    import json
    import shutil
    import subprocess
    root = Path(__file__).resolve().parent.parent
    web, bar = root / "extension/lib/vpn-core.js", root / "dms-plugin/lib/Vpn.js"
    check("the extension's and DankBar's copies are identical", web.read_bytes() == bar.read_bytes())
    node = shutil.which("node")
    if not node:
        print("  (node not installed: skipping the comparison)")
        return
    entries = ["https://www.MediaFire.com/file/x", "*.example.org", "host.net:8080/p", " WWW.a.b ",
               "http://user@files.example.com:81/x", "plain"]
    urls = ["https://download123.mediafire.com/a.zip", "https://mediafire.com/a", "https://notmediafire.com/a",
            "http://a.b/x", "https://user:pw@dl.example.org:8443/f", "magnet:?xt=urn:btih:abc", "not a url"]
    sites = ["mediafire.com", "example.org", "a.b"]
    script = web.read_text() + f"""
const entries = {json.dumps(entries)}, urls = {json.dumps(urls)}, sites = {json.dumps(sites)};
console.log(JSON.stringify({{ sites: entries.map(vpnSiteOf), hits: urls.map((u) => vpnOnList(u, sites)),
  count: vpnCountOnList(urls, sites) }}));"""
    out = json.loads(subprocess.run([node, "-e", script], capture_output=True, text=True, check=True).stdout)
    expected_sites = [vpn_mod.site_of(e) for e in entries]
    expected_hits = [vpn_mod.on_list(u, sites) for u in urls]
    check("it reads sites the way the manager does", out["sites"] == expected_sites, f"{out['sites']} vs {expected_sites}")
    check("and catches the same links", out["hits"] == expected_hits and out["count"] == sum(expected_hits),
          f"{out['hits']} vs {expected_hits}")


def test_config() -> None:
    print("\nwireproxy's config")
    text = vpn_mod.wireproxy_config(PROTON + "CheckAlive = 9.9.9.9\n", 25345)
    lines = text.splitlines()
    check("the WireGuard config is kept whole", "PrivateKey = c2VjcmV0LWtleS1mb3ItdGVzdHMtb25seS0wMDAwMDA=" in lines
          and "Endpoint = 203.0.113.7:51820" in lines)
    check("a CheckAlive ping to the tunnel's DNS follows [Interface], replacing the file's own",
          lines[lines.index("[Interface]") + 1] == "CheckAlive = 10.2.0.1"
          and "CheckAlive = 9.9.9.9" not in lines, text)
    check("the HTTP proxy is on localhost only", text.rstrip().endswith("[http]\nBindAddress = 127.0.0.1:25345"))
    no_dns = vpn_mod.wireproxy_config(PROTON.replace("DNS = 10.2.0.1\n", ""), 1)
    check("without a DNS line it pings 1.1.1.1", "CheckAlive = 1.1.1.1" in no_dns)


async def test_process(tmp: Path) -> None:
    print("\nrunning wireproxy (fake)")
    folder = tmp / "wireguard"
    folder.mkdir()
    (folder / "proton-NL-FREE#1.conf").write_text(PROTON)
    (folder / "proton-JP-FREE#2.conf").write_text(PROTON)
    fake = tmp / "wireproxy"
    fake.write_text(FAKE_WIREPROXY)
    fake.chmod(0o755)
    os.environ["FAKE_WG_LOG"] = str(tmp / "wg.log")
    os.environ["FAKE_WG_DOWN"] = str(tmp / "down")

    port = free_port()
    vpn = vpn_mod.Vpn(Cfg({"enabled": True, "folder": str(folder), "server": "proton-NL-FREE#1.conf",
                           "port": port, "binary": str(fake)}), tmp / "state")
    # The info port is port + 1; make sure it is free too.
    while True:
        try:
            import socket
            with socket.socket() as s:
                s.bind(("127.0.0.1", port + 1))
            break
        except OSError:
            port = free_port()
            vpn.cfg.data["vpn"]["port"] = port
    check("servers are the .conf files, sorted", vpn.servers() == ["proton-JP-FREE#2.conf", "proton-NL-FREE#1.conf"])
    await vpn.start()
    up = await wait_for(lambda: vpn.connected, 10)
    check("it starts wireproxy and sees the tunnel answer", up, vpn.status().get("lastError", ""))
    argv = (tmp / "wg.log").read_text().split()
    conf = tmp / "state" / "wireproxy.conf"
    check("wireproxy runs silent on our config with the health check on port + 1",
          argv[:3] == ["-s", "-c", str(conf)] and argv[-1] == f"127.0.0.1:{port + 1}", " ".join(argv))
    check("the config with the private key is for this user alone",
          stat.S_IMODE(conf.stat().st_mode) == 0o600, oct(conf.stat().st_mode))

    (tmp / "down").write_text("")
    check("a tunnel that stops answering reads as not connected", await wait_for(lambda: not vpn.connected, 10))
    (tmp / "down").unlink()
    check("and connected again once it answers", await wait_for(lambda: vpn.connected, 10))

    proc = vpn.proc
    await vpn.stop()
    check("stopping ends wireproxy", proc is not None and proc.returncode is not None)

    vpn.cfg.data["vpn"]["binary"] = str(tmp / "missing")
    await vpn.start()
    check("without wireproxy it says how to install it", "pacman -S wireproxy" in vpn.last_error, vpn.last_error)


async def test_api(tmp: Path) -> None:
    print("\nrouting downloads (API, fake aria2)")
    rpc_port = free_port()
    httpd, fake = serve(rpc_port, secret="s")
    folder = tmp / "wg-api"
    folder.mkdir()
    (folder / "proton.conf").write_text(PROTON)
    config = tmp / "config.yaml"
    config.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp / "m.sock")},
        "poll_interval": 0.5,
        "aria2": {"managed": False, "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "s"}},
        "history": {"enabled": False, "file": str(tmp / "h.json")},
        # The binary does not exist: these checks are about routing, and a
        # download set to use the VPN must be routed to it even while it is down.
        "vpn": {"enabled": False, "folder": str(folder), "binary": str(tmp / "no-wireproxy")},
    }))
    cfg = Config(config)
    app = create_app(cfg)
    runner = ManagerRunner(app)
    task = asyncio.create_task(runner.serve())
    try:
        async with IPCSession(cfg.get("server.socket")) as http:
            async def post(path, body=None):
                async with http.post(path, json=body) as res:
                    return res.status, await res.json()

            async def get(path):
                async with http.get(path) as res:
                    return res.status, await res.json()

            await wait_for(lambda: runner.started, 15)

            def options_of(name: str) -> dict:
                dl = next((d for d in fake.downloads.values() if d.name == name), None)
                return dl.options if dl else {}

            await post("/api/downloads", {"uris": ["http://files.example.com/off.bin"],
                                          "options": {"vpn": "on"}})
            check("with the VPN off in Settings, nothing is routed",
                  "all-proxy" not in options_of("off.bin") and "vpn" not in options_of("off.bin"),
                  str(options_of("off.bin")))

            status, state = await post("/api/vpn", {"enabled": True, "sites": ["https://www.mediafire.com/"]})
            check("Settings turn it on and keep the site as a host",
                  status == 200 and state["enabled"] and state["sites"] == ["mediafire.com"]
                  and state["servers"] == ["proton.conf"], str(state))
            check("and it is saved to config.yaml",
                  yaml.safe_load(config.read_text())["vpn"]["sites"] == ["mediafire.com"])

            proxy = state["proxy"]
            await post("/api/downloads", {"uris": ["https://dl7.mediafire.com/listed.zip",
                                                   "https://other.example.org/plain.zip"]})
            await post("/api/downloads", {"uris": ["https://other.example.org/forced.zip"],
                                          "options": {"vpn": "on"}})
            await post("/api/downloads", {"uris": ["https://www.mediafire.com/skipped.zip"],
                                          "options": {"vpn": "off"}})
            await post("/api/intake/add", {"url": "https://mediafire.com/browser.zip", "cookie": "a=b"})
            check("a listed site's download goes through the VPN", options_of("listed.zip").get("all-proxy") == proxy)
            check("next to it, another site's goes direct", "all-proxy" not in options_of("plain.zip"))
            check("a download set on uses it whatever its site", options_of("forced.zip").get("all-proxy") == proxy)
            check("a download set off goes direct even from a listed site",
                  "all-proxy" not in options_of("skipped.zip"))
            check("so does a browser download from a listed site",
                  options_of("browser.zip").get("all-proxy") == proxy, str(options_of("browser.zip")))
            torrent = base64.b64encode(b"d4:infod4:name4:t.isoee").decode()
            status, _ = await post("/api/downloads/file", {"data": torrent, "kind": "torrent", "filename": "t.torrent",
                                                           "options": {"vpn": "on"}})
            check("a torrent file added with a VPN choice is added, and goes direct", status == 200
                  and not any(d.options.get("all-proxy") for d in fake.downloads.values()
                              if d.name not in ("listed.zip", "forced.zip", "browser.zip")), str(status))
            check("aria2 never sees the choice itself",
                  not any("vpn" in d.options for d in fake.downloads.values()))

            plain = next(g for g, d in fake.downloads.items() if d.name == "plain.zip")
            status, _ = await post(f"/api/download/{plain}/vpn", {"on": True})
            check("one download can be switched onto the VPN", status == 200
                  and options_of("plain.zip").get("all-proxy") == proxy, str(options_of("plain.zip")))
            status, _ = await post(f"/api/download/{plain}/vpn", {"on": False})
            check("and back to direct", status == 200 and options_of("plain.zip").get("all-proxy") == "")
            listed = next(g for g, d in fake.downloads.items() if d.name == "listed.zip")
            seen = await wait_for(lambda: listed in app.state.vpn.status()["routed"], 6)
            check("the state lists which downloads use the VPN", seen, str(app.state.vpn.status()["routed"]))
            _, state = await get("/api/state")
            check("and the live state carries the VPN's status",
                  state.get("vpn", {}).get("enabled") is True and "connected" in state.get("vpn", {}))
    finally:
        runner.stop()
        await asyncio.wait_for(task, 10)
        httpd.shutdown()


async def main() -> int:
    test_choosing()
    test_shared_js()
    test_config()
    with tempfile.TemporaryDirectory(prefix="aria-vpn-test-") as tmp:
        await test_process(Path(tmp))
        await test_api(Path(tmp))
    return summary()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
