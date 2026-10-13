"""Addon Forge CLI -- development foundation, not a production IDE."""
import argparse
import json
from pathlib import Path
import shutil
import sys

from . import __version__
from .config import load_config
from .validate import check_addon, is_valid


def make_parser():
    parser = argparse.ArgumentParser(prog="forge", description="WotLK 3.3.5a addon workbench")
    parser.add_argument("--config", type=Path, default=Path("forge.toml"))
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor")
    check = sub.add_parser("check")
    check.add_argument("addon", type=Path)
    dep = sub.add_parser("deploy")
    dep.add_argument("addon", type=Path)
    client = sub.add_parser("client")
    client_sub = client.add_subparsers(dest="action", required=True)
    client_sub.add_parser("start")
    cmd = client_sub.add_parser("command")
    cmd.add_argument("text")
    shot = client_sub.add_parser("screenshot")
    shot.add_argument("output", type=Path)
    test = sub.add_parser("test")
    test.add_argument("--suite", default="smoke")
    test.add_argument("--require-test", action="append", default=[], help="Require named in-game assertion")
    test.add_argument("--output", type=Path, default=Path(".forge-runs"))
    realm = sub.add_parser("realm")
    realm.add_argument("action", choices=["up", "down", "status"])
    ai = sub.add_parser("ai")
    ai_sub = ai.add_subparsers(dest="action", required=True)
    create = ai_sub.add_parser("create")
    create.add_argument("name")
    create.add_argument("prompt")
    create.add_argument("--out", type=Path, default=Path("projects"))
    repair = ai_sub.add_parser("repair")
    repair.add_argument("addon", type=Path)
    repair.add_argument("--in-client", action="store_true")
    repair.add_argument("--max-attempts", type=int, default=3)
    return parser


def main(argv=None) -> int:
    args = make_parser().parse_args(argv)
    try:
        if args.command == "check":
            diagnostics = check_addon(args.addon)
            for d in diagnostics:
                print(f"{d.severity.upper()}: {d.message}")
            if is_valid(diagnostics):
                print("Static checks passed (this does not prove in-client correctness)")
                return 0
            return 1
        if args.command == "ai" and args.action == "create":
            from .ai import create_addon
            files = create_addon(args.out / args.name, args.prompt)
            print(json.dumps({"created": files}, indent=2))
            return 0
        if args.command == "ai" and args.action == "repair" and not args.in_client:
            from .ai import repair_addon
            result = repair_addon(args.addon, max_attempts=args.max_attempts)
            print(json.dumps(result, indent=2, default=str))
            return 0 if result["status"] == "passed" else 1
        cfg = load_config(args.config)
        if args.command == "doctor":
            for key, binary in [("Python", "python3"), ("Wine", "wine"), ("X11 automation", "xdotool"),
                                ("Lua 5.1 compiler", "luac5.1"), ("Screenshot", "import"), ("Docker", "docker")]:
                print(f"{key:20} {shutil.which(binary) or 'NOT FOUND'}")
            print(f"WoW directory: {cfg.wow_dir} | exists: {cfg.wow_dir.is_dir()}")
            print(f"Realm source: {cfg.realm_dir or 'not configured'}")
            return 0
        if args.command == "deploy":
            from .deploy import deploy
            print(deploy(args.addon, cfg.wow_dir))
            return 0
        if args.command == "client":
            from .client import ClientController
            client = ClientController(cfg)
            if args.action == "start":
                print(f"Client started, PID: {client.start()}")
            elif args.action == "command":
                client.command(args.text)
                print("Command sent; game receipt is not guaranteed")
            elif args.action == "screenshot":
                print(client.screenshot(args.output))
            return 0
        if args.command == "test":
            from .runner import run_smoke
            result = run_smoke(cfg, suite=args.suite, out_dir=args.output, required_tests=tuple(args.require_test))
            print(json.dumps(result.__dict__, indent=2))
            return 0 if result.status == "passed" else 1
        if args.command == "realm":
            import subprocess
            if not cfg.realm_dir or not (cfg.realm_dir / "docker-compose.yml").exists() and not (cfg.realm_dir / "compose.yml").exists() and not (cfg.realm_dir / "compose.yaml").exists():
                raise ValueError("[realm] source_dir must point to an existing AzerothCore Docker Compose checkout")
            command = {"up": ["up", "-d", "--build"], "down": ["down"], "status": ["ps"]}[args.action]
            return subprocess.run(["docker", "compose", *command], cwd=cfg.realm_dir, check=False).returncode
        if args.command == "ai" and args.action == "repair":
            from .ai import repair_addon
            result = repair_addon(args.addon, cfg=cfg, in_client=True, max_attempts=args.max_attempts)
            print(json.dumps(result, indent=2, default=str))
            return 0 if result["status"] == "passed" else 1
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"forge: {exc}", file=sys.stderr)
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
