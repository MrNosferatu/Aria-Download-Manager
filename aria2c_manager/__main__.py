"""CLI entrypoint: python -m aria2c_manager"""

from __future__ import annotations

import argparse
import asyncio
import signal
import sys
from pathlib import Path

from .api import VERSION, create_app, run
from .config import DEFAULT_STATE_DIR, PROJECT_DIR, Config
from .ipc import SocketInUse, socket_path_for


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aria2c-manager",
        description="Background aria2c server for the browser extension and the "
        "DankMaterialShell widget, reachable only through its Unix socket.",
    )
    parser.add_argument(
        "-c", "--config", default=None, help="config file (default: ./config.yaml)"
    )
    parser.add_argument(
        "--no-aria2",
        action="store_true",
        help="do not spawn aria2c; attach to an already-running RPC instance",
    )
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
    parser.add_argument(
        "--install-native-host",
        action="store_true",
        help="register the browser extension's native-messaging host (IPC bridge) and exit",
    )
    parser.add_argument(
        "--chrome-extension-id",
        action="append",
        default=[],
        metavar="ID",
        help="with --install-native-host: allow this Chromium extension id "
        "(found automatically when the extension is loaded unpacked from this checkout)",
    )
    parser.add_argument("-V", "--version", action="version", version=VERSION)
    return parser


async def serve(cfg: Config) -> None:
    app = create_app(cfg)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    # SIGHUP is what a closing terminal sends; SIGTERM is systemd and
    # /api/restart. All of them get the full shutdown, so aria2c is never left
    # orphaned holding the RPC port.
    for name in ("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"):
        if sig := getattr(signal, name, None):
            loop.add_signal_handler(sig, stop.set)
    await run(app, stop)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    config_path = Path(args.config) if args.config else PROJECT_DIR / "config.yaml"
    if not config_path.is_file() and args.config:
        print(f"config not found: {config_path}", file=sys.stderr)
        return 2

    cfg = Config(config_path)
    if args.no_aria2:
        cfg.data["aria2"]["managed"] = False

    if args.print_config:
        import json

        print(json.dumps(cfg.public(), indent=2))
        return 0

    if args.install_native_host:
        from .native_host import install

        socket_path = socket_path_for(cfg)
        for line in install(socket_path, PROJECT_DIR / "extension",
                            args.chrome_extension_id, DEFAULT_STATE_DIR):
            print(line)
        print(f"socket     {socket_path}")
        print("Restart the browser (or reload the extension) to pick it up.")
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

    print(f"aria2c-manager {VERSION}")
    print(f"  socket     {socket_path_for(cfg)}")
    print(f"  config     {cfg.path}", flush=True)
    try:
        asyncio.run(serve(cfg))
    except SocketInUse as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
