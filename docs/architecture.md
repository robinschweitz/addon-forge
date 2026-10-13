# Implementation boundaries

1. **Host/Nix** supplies Python, Lua 5.1, Wine, Docker tooling and X11 test dependencies. It does not package proprietary game data.
2. **Python CLI** handles source files and invokes typed test actions; model text never becomes shell commands.
3. **Client runner** launches the user-provided executable with a dedicated Wine prefix, interacts with an already-running in-world client through X11, captures images, and correlates output by random run ID.
4. **ForgeTestBridge** registers Lua assertions and records error messages in a global SavedVariable, which WoW writes on logout/UI reload.
5. **Realm** is a separate AzerothCore Docker installation. v0.1 provides lifecycle wrappers only; fixtures are not implemented.
6. **AI agent** creates and changes only whitelisted addon source files, subject to static tests and optional live-client tests, with rollback on exhausted attempts.

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
