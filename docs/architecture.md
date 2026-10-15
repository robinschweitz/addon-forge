# Implementation boundaries

1. **Host/Nix** supplies Python, Wine, Docker tooling and X11 test dependencies. Lua 5.1 is embedded through `lupa`, so checks and specs need no system Lua. It does not package proprietary game data.
2. **Python CLI** handles source files and invokes typed test actions; model text never becomes shell commands.
3. **Offline layer** (no client): `validate.py` compiles with real Lua 5.1 and reads bytecode for global/field/method use against `wowapi.py` (known-absent APIs plus an optional `_G`/widget-method dump from the test client). `headless/` runs the addon in a sandboxed 3.3.5a emulation with offline specs. Both gate every real-client run.
4. **Client runner** supports Wine/X11 and a verified native Windows test copy. On Windows all automation goes through the WoWControlSDK (login, character entry, bridge calls, API dump); keyboard input is limited to `/targetexact` for peer fixtures.
5. **ForgeTestBridge v3** records assertions, Lua errors and independent player/target/party/frame/chat/event/watched-global telemetry, returned as JSON through the SDK (Windows) or SavedVariables on `/reload` (Wine).
6. **Realm** is a separate loopback-only AzerothCore Docker installation. AzerothGhost supports fixed smoke fixtures, short-lived peer clients and the `master_loot` plan fixture.
7. **Agents** (OpenCode via [AGENTS.md](../AGENTS.md), or any MCP client) use `forge mcp` tools. Real-client runs require the human to start the server with `--allow-fixtures`.

See the [canonical QA workflow](qa-workflow.md) for commands, verification status and safety boundaries.

## Open problems to address before unattended mode

- Confirm error handler behavior on a pristine WotLK 3.3.5a client, including loading-order errors and handler replacement by other addons.
- Avoid event timing races around `/reload` and SavedVariables flush (Wine path only; Windows uses the SDK JSON transport).
- Pin Nix store dependencies using `flake.lock`, and pin AzerothCore source/image/database fixture versions.
- Add combat and quest fixtures; the offline harness already provides a synthetic state driver for specs.
- Add adversarial tests for model-generated source and consistent crash/infrastructure triage.
- Gate release artifacts on real in-client assertions, regression suites, and human approval.

## Test result semantics

* `passed`: complete matching report, nonempty test suite, all assertions passed, no captured errors.
* `failed`: complete matching report, at least one failing assertion or captured Lua error.
* `infrastructure_error`: client inaccessible, no fresh matching SavedVariables file, or malformed report.

There is no claim that a model can perfectly diagnose arbitrary UI bugs from screenshots. Vision checks will supplement, not replace, deterministic assertions.
