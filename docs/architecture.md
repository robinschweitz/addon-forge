# Implementation boundaries

1. **Host/Nix** supplies Python, Lua 5.1, Wine, Docker tooling and X11 test dependencies. It does not package proprietary game data.
2. **Python CLI** handles source files and invokes typed test actions; model text never becomes shell commands.
3. **Client runner** supports Wine/X11 and a verified native Windows test copy with constrained game commands, screenshots and correlated reports. Optional calibrated local-account login does not select a character.
4. **ForgeTestBridge v2** records assertions, errors and independent player/target/party/frame telemetry in SavedVariables on UI reload.
5. **Realm** is a separate loopback-only AzerothCore Docker installation. AzerothGhost supports fixed smoke fixtures and short-lived peer clients; staged bot-party lifecycle remains unverified live.
6. **AI agent**: built-in `forge ai` uses an OpenAI-compatible backend. OpenCode separately follows [AGENTS.md](../AGENTS.md) to author addons and plans using the bounded QA CLI. Native OpenCode backend and unattended comprehensive QA remain future work.

See the [canonical QA workflow](qa-workflow.md) for commands, verification status and safety boundaries.

## Open problems to address before unattended mode

- Confirm error handler behavior on a pristine WotLK 3.3.5a client, including loading-order errors and handler replacement by other addons.
- Detect world-ready state from bridge and client state before sending chat input.
- Avoid event timing races around `/reload` and SavedVariables flush.
- Pin Nix store dependencies using `flake.lock`, and pin AzerothCore source/image/database fixture versions.
- Add a deterministic server API for combat/party/raid fixtures and a test-only synthetic state driver.
- Add adversarial tests for model-generated source and consistent crash/infrastructure triage.
- Gate release artifacts on real in-client assertions, regression suites, and human approval.

## Test result semantics

* `passed`: complete matching report, nonempty test suite, all assertions passed, no captured errors.
* `failed`: complete matching report, at least one failing assertion or captured Lua error.
* `infrastructure_error`: client inaccessible, no fresh matching SavedVariables file, or malformed report.

There is no claim that a model can perfectly diagnose arbitrary UI bugs from screenshots. Vision checks will supplement, not replace, deterministic assertions.
