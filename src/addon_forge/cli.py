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
    start_client = client_sub.add_parser("start")
    start_client.add_argument("--login", action="store_true", help="Launch new test WoW and log in using Windows vault credentials")
    login = client_sub.add_parser("login", help="Manage Windows-only automated test login")
    login.add_argument("mode", choices=["save", "calibrate"])
    login.add_argument("--account", help="Test-only realm account name for save mode")
    char = client_sub.add_parser("character", help="Calibrate isolated test character selection")
    char.add_argument("mode", choices=["calibrate"])
    char.add_argument("--character", required=True)
    video = client_sub.add_parser("windowed", help="Configure test client video settings while WoW is closed")
    video.add_argument("--resolution", default="1280x720")
    cmd = client_sub.add_parser("command")
    cmd.add_argument("text")
    shot = client_sub.add_parser("screenshot")
    shot.add_argument("output", type=Path)
    test = sub.add_parser("test")
    test.add_argument("--suite", default="smoke")
    test.add_argument("--require-test", action="append", default=[], help="Require named in-game assertion")
    test.add_argument("--output", type=Path, default=Path(".forge-runs"))
    tunnel = sub.add_parser("tunnel", help="SSH-forward private realm TCP 3724 and 8085")
    tunnel.add_argument("host")
    tunnel.add_argument("--user", default="root")
    tunnel.add_argument("--identity", type=Path)
    tunnel.add_argument("--port", type=int, default=22)
    realmlist = sub.add_parser("realmlist", help="Back up and point WoW at SSH-tunneled local realm")
    realmlist.add_argument("--locale")
    local = sub.add_parser("local-realm", help="Set up a separate local AzerothCore test realm")
    local.add_argument("action", choices=["setup", "start", "status", "logs", "console", "stop", "create-account"])
    local.add_argument("--account-name", help="Local realm account name (password prompted securely)")
    local.add_argument("--source-wow", type=Path, help="Original WoW client directory (read-only)")
    local.add_argument("--test-wow", type=Path, help="New isolated WoW test copy")
    local.add_argument("--realm-dir", type=Path, help="AzerothCore checkout directory")
    local.add_argument("--locale", default=None, help="WoW locale (enUS, deDE, ...)")
    local.add_argument("--approve-local-setup", action="store_true")
    local.add_argument("--db-port", type=int, help="Host-side MySQL port, e.g. 13306")
    local.add_argument("--approve-port-change", action="store_true")
    local.add_argument("--adopt-existing-test-wow", action="store_true",
                       help="Explicitly reuse an existing separate WoW copy")
    agent = sub.add_parser("agent", help="Agent-facing inspectable local test realm capabilities")
    agent_sub = agent.add_subparsers(dest="action", required=True)
    agent_sub.add_parser("capabilities")
    agent_sub.add_parser("wowcontrol-status", help="Read SDK screen state from the marked test client without login or input")
    sdk = agent_sub.add_parser("wowcontrol-setup", help="Pin, build and configure external WoWControlSDK for the private test copy")
    sdk.add_argument("--approve-build", action="store_true", help="Authorize compiling third-party C++ source")
    sdk.add_argument("--install-prereqs", action="store_true", help="Opt in to winget installing missing Git, CMake and Visual Studio Build Tools")
    sdk.add_argument("--realm-name", help="Exact local AzerothCore realm name (enables SDK backend)")
    sdk.add_argument("--workspace", type=Path, help="Separate source/build directory; default .forge-tools/wowcontrol-sdk")
    session = agent_sub.add_parser("session", help="Start verified WoW and run a bounded addon plan")
    session.add_argument("plan", type=Path)
    session.add_argument("--approve-fixtures", action="store_true")
    lifecycle = agent_sub.add_parser("party-lifecycle", help="Run 2-4 persistent peers and verify before/after departure")
    lifecycle.add_argument("--character", required=True)
    lifecycle.add_argument("--peers", type=int, default=3)
    lifecycle.add_argument("--approve-fixtures", action="store_true")
    prepare = agent_sub.add_parser("prepare", help="Safely deploy bridge and start isolated test WoW if needed")
    prepare.add_argument("--start-client", action="store_true")
    prepare.add_argument("--login", action="store_true", help="Use calibrated Windows-vault login for a newly started client")
    prepare.add_argument("--enter-character", help="Enter the selected test character after verified login")
    workflow = agent_sub.add_parser("run-plan", help="Review or execute a bounded addon acceptance plan")
    workflow.add_argument("plan", type=Path)
    workflow.add_argument("--approve-fixtures", action="store_true")
    peer = agent_sub.add_parser("peer-test", help="Synchronize real AzerothGhost peer with graphical WoW target test")
    peer.add_argument("--character", required=True, help="Already logged-in private-realm character name")
    peer.add_argument("--approve-fixtures", action="store_true")
    fixture = agent_sub.add_parser("realm-fixture", help="Run an approved official AzerothGhost fixture")
    fixture.add_argument("scenario", choices=["create-character", "login-world", "teleport"])
    fixture.add_argument("--realm-dir", type=Path)
    fixture.add_argument("--approve-fixtures", action="store_true")
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
        if args.command == "agent":
            from .agent_realm import capabilities, run_realm_smoke
            if args.action == "wowcontrol-setup":
                from .wowcontrol_build import setup
                result = setup(args.config, approve=args.approve_build,
                               realm=args.realm_name, workspace=args.workspace,
                               install_prereqs=args.install_prereqs)
                print(json.dumps(result, indent=2))
                return 0 if result["status"] in ("plan_only", "built") else 1
            if args.action == "wowcontrol-status":
                from .wowcontrol import client_status
                print(json.dumps(client_status(load_config(args.config)), indent=2))
                return 0
            if args.action == "capabilities":
                print(json.dumps(capabilities(), indent=2))
                return 0
            if args.action == "session":
                from .agent_session import run_session
                result = run_session(load_config(args.config), args.plan,
                                     approve=args.approve_fixtures)
                print(json.dumps(result, indent=2))
                return 0 if result["status"] in ("plan_only", "passed") else 1
            if args.action == "prepare":
                from .agent_prepare import prepare_environment
                result = prepare_environment(load_config(args.config), start_client=args.start_client,
                                             login=args.login, enter_character=args.enter_character)
                print(json.dumps(result, indent=2))
                return 0
            if args.action == "party-lifecycle":
                from .peer_scenario import peer_scenario
                result = peer_scenario(load_config(args.config), character=args.character,
                                       peers=args.peers, lifecycle=True,
                                       approve=args.approve_fixtures,
                                       output_dir=Path(".forge-runs"))
                print(json.dumps(result, indent=2))
                return 0 if result["status"] in ("plan_only", "passed") else 1
            if args.action == "run-plan":
                from .agent_workflow import run_plan
                result = run_plan(load_config(args.config), args.plan,
                                  approve=args.approve_fixtures)
                print(json.dumps(result, indent=2))
                return 0 if result["status"] in ("plan_only", "passed") else 1
            if args.action == "peer-test":
                from .peer_scenario import peer_scenario
                result = peer_scenario(load_config(args.config), character=args.character,
                                       approve=args.approve_fixtures)
                print(json.dumps(result, indent=2))
                return 0 if result["status"] in ("plan_only", "passed") else 1
            root = args.realm_dir or (Path.cwd().parent / "azerothcore-wotlk")
            result = run_realm_smoke(root, scenario=args.scenario, approve=args.approve_fixtures)
            print(json.dumps(result, indent=2))
            return 0 if result["status"] in ("plan_only", "passed") else 1
        if args.command == "local-realm":
            from .local_realm import setup, operate, start_existing
            realm = args.realm_dir or (Path.cwd().parent / "azerothcore-wotlk")
            if args.action == "create-account":
                from .local_account import create_test_account
                if not args.account_name:
                    raise ValueError("Supply --account-name (password is prompted privately)")
                from .local_realm import verify_azerothcore_checkout, check_tools, check_compose
                if not verify_azerothcore_checkout(realm):
                    raise RuntimeError("No official AzerothCore checkout found")
                check_tools()
                check_compose(realm)
                create_test_account(args.account_name)
                return 0
            if args.action == "setup":
                if not args.test_wow:
                    raise ValueError("Supply --test-wow for local-realm setup")
                setup(args.source_wow, args.test_wow, realm, args.locale,
                      Path("forge.local.toml"), approve=args.approve_local_setup,
                      adopt_existing=args.adopt_existing_test_wow)
                return 0
            if args.action == "start":
                return start_existing(realm, db_port=args.db_port,
                                      approve_port_change=args.approve_port_change)
            return operate(args.action, realm)
        cfg = load_config(args.config)
        if args.command == "doctor":
            requirements = ([("Python", "python"), ("Docker", "docker")]
                            if sys.platform == "win32" else
                            [("Python", "python3"), ("Wine", "wine"), ("X11 automation", "xdotool"),
                             ("Lua 5.1 compiler", "luac5.1"), ("Screenshot", "import"), ("Docker", "docker")])
            for key, binary in requirements:
                print(f"{key:20} {shutil.which(binary) or 'NOT FOUND'}")
            if sys.platform == "win32":
                try:
                    from PIL import ImageGrab  # noqa: F401
                    print("Windows screenshots  Pillow available")
                except ImportError:
                    print("Windows screenshots  NOT FOUND (pip install addon-forge[windows])")
            print(f"WoW directory: {cfg.wow_dir} | exists: {cfg.wow_dir.is_dir()}")
            print(f"Realm source: {cfg.realm_dir or 'not configured'}")
            return 0
        if args.command == "tunnel":
            from .realm_connect import tunnel as run_tunnel
            return run_tunnel(args.host, user=args.user, identity=args.identity, port=args.port)
        if args.command == "realmlist":
            from .realm_connect import configure_realmlist
            path, backup = configure_realmlist(cfg.wow_dir, locale=args.locale)
            print(f"Realmlist configured: {path} (original backup: {backup})")
            return 0
        if args.command == "deploy":
            from .deploy import deploy
            print(deploy(args.addon, cfg.wow_dir))
            return 0
        if args.command == "client" and args.action == "character":
            from .win_character import calibrate_character
            print(calibrate_character(load_config(args.config), args.character))
            return 0
        if args.command == "client" and args.action == "login":
            from .win_login import calibrate, save_credentials
            if args.mode == "save":
                if not args.account:
                    raise ValueError("Supply --account for client login save")
                save_credentials(cfg.wow_dir, args.account)
            else:
                print(calibrate(cfg))
            return 0
        if args.command == "client" and args.action == "windowed":
            from .client_settings import configure_windowed
            path, backup = configure_windowed(cfg.wow_dir, resolution=args.resolution)
            print(f"Windowed configuration: {path} | backup: {backup or 'no existing config'}")
            print("Start the test client again to apply the settings.")
            return 0
        if args.command == "client":
            from .client import ClientController
            client = ClientController(cfg)
            if args.action == "start":
                if args.login:
                    from .win_login import start_and_login
                    print(f"Client login initiated, PID: {start_and_login(cfg)}")
                else:
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
