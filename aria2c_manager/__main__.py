"""CLI entrypoint: python -m aria2c_manager"""

from __future__ import annotations

import argparse
import signal
import sys
import webbrowser
from pathlib import Path

import uvicorn

from .api import VERSION, create_app
from .config import PROJECT_DIR, Config


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aria2c-manager",
        description="Background aria2c server with a web UI and a Tampermonkey intake endpoint.",
    )
    parser.add_argument(
        "-c", "--config", default=None, help="config file (default: ./config.yaml)"
    )
    parser.add_argument("--host", default=None, help="override server.host")
    parser.add_argument("--port", type=int, default=None, help="override server.port")
    parser.add_argument(
        "--no-aria2",
        action="store_true",
        help="do not spawn aria2c; attach to an already-running RPC instance",
    )
    parser.add_argument("--open", action="store_true", help="open the web UI in a browser")
    parser.add_argument(
        "--print-config",
        action="store_true",
        help="print the effective config and exit",
    )
    parser.add_argument(
        "--print-argv",
        action="store_true",
        help="print the aria2c command line that would be used and exit",
    )
    parser.add_argument("--log-level", default="info", help="uvicorn log level")
    parser.add_argument("-V", "--version", action="version", version=VERSION)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    config_path = Path(args.config) if args.config else PROJECT_DIR / "config.yaml"
    if not config_path.is_file() and args.config:
        print(f"config not found: {config_path}", file=sys.stderr)
        return 2

    cfg = Config(config_path)
    if args.host:
        cfg.data["server"]["host"] = args.host
    if args.port:
        cfg.data["server"]["port"] = args.port
    if args.no_aria2:
        cfg.data["aria2"]["managed"] = False

    if args.print_config:
        import json

        print(json.dumps(cfg.public(), indent=2))
        return 0

    if args.print_argv:
        from .rpc import Aria2RPC
        from .supervisor import Aria2Supervisor

        rpc = Aria2RPC(cfg.get("aria2.rpc.host"), int(cfg.get("aria2.rpc.port")))
        supervisor = Aria2Supervisor(cfg, rpc, lambda *a, **k: None)
        try:
            print(" \\\n  ".join(supervisor.build_argv()))
        except Exception as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        return 0

    host = str(cfg.get("server.host", "127.0.0.1"))
    port = int(cfg.get("server.port", 6810))
    url = f"http://{'127.0.0.1' if host in ('0.0.0.0', '::') else host}:{port}/"

    app = create_app(cfg)
    print(f"aria2c-manager {VERSION}")
    print(f"  web UI     {url}")
    print(f"  userscript POST {url}api/userscript/add")
    print(f"  config     {cfg.path}")
    if host not in ("127.0.0.1", "localhost", "::1"):
        print(
            f"  WARNING: bound to {host} with no authentication — anyone who can reach\n"
            "           this port can queue downloads and read your download list.",
            file=sys.stderr,
        )
    if args.open or cfg.get("server.open_browser"):
        webbrowser.open(url)

    server = uvicorn.Server(
        uvicorn.Config(app, host=host, port=port, log_level=args.log_level, access_log=False)
    )
    # uvicorn handles SIGINT/SIGTERM but not SIGHUP, which is what a closing
    # terminal sends. Without this the process dies instantly, the shutdown path
    # never runs, and aria2c is left orphaned holding the RPC port.
    for name in ("SIGHUP", "SIGQUIT"):
        if sig := getattr(signal, name, None):
            try:
                signal.signal(sig, server.handle_exit)
            except (ValueError, OSError):
                pass  # not the main thread / unsupported platform
    server.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
