# Addon Forge Security

This file owns the secure-coding rules for Addon Forge and for addons built
with it, and the open security decisions. Behaviour is in
[REQUIREMENTS.md](REQUIREMENTS.md), components and trust boundaries (`TB-`)
are in [ARCHITECTURE.md](ARCHITECTURE.md), and UI rendering rules are in
[DESIGN.md](DESIGN.md). Threats (`T-`) are in [THREAT_MODEL.md](THREAT_MODEL.md).

Rule status: `ACTIVE` (enforced today), `PLANNED` (decided, enforcement point
named, not built yet), `BLOCKED` (waits for an `OD-` decision).

## Secure-Coding Inputs

Documents read: `REQUIREMENTS.md`, `ARCHITECTURE.md`, `DESIGN.md`,
the capability boundaries of the former `AGENTS.md` (before commit `d9a218e`;
now in this file), `README.md` (Security notes),
`docs/agent-playbook.md`, `docs/local-realm.md`, the source modules named
below, their tests, and PR #14 (Linux headless). No separate security notes
were given.

Confirmed facts that justify the rules:

- Forge runs on the user's own machine for the owner and a few friends
  (NFR-1.11). Everything a run touches is local: a marked WoW test copy and a
  loopback-only AzerothCore realm in Docker.
- Untrusted input: AI agent commands and plans (TB-1); addon and spec source,
  often AI-written (TB-2); the third-party WoWControlSDK (TB-4); bridge
  reports from the client (TB-5); other players' chat and addon messages,
  which addons read in raids.
- Secrets: realm account passwords (vault), the realm's MySQL root password
  (`.env` in the AzerothCore checkout), and the user's other WoW installation
  (Rising Gods) with its own credentials.
- Addons leave the test machine: `forge release` (FR-15) publishes them to
  the raiders.

Gaps and conflicts:

- ARCHITECTURE.md AQ-3 adds no SOAP entry point, but the AzerothCore compose
  still publishes the SOAP port on `127.0.0.1` (`local_realm.py`); SC-024
  closes it.
- `scripts/setup_wizard.py` and `scripts/client_fetch.py` serve only the NixOS
  VM, which is TO BE REMOVED (FR-13.2). Their download checks are not carried
  into these rules.
- The rule "never upload client files, secrets or credential screenshots to
  an AI provider" (SC-018) has no technical enforcement; accepted
  (OD-006).

## Selected Manicode Prompts

Corpus root: `UNKNOWN`. The Manicode secure-coding corpus that the source
playbook uses is not available in this environment, so no pack is
`SELECTED`. Candidate packs from the playbook (Node.js, React Native, Fastify,
Better Auth, Keycloak, Cedar, OpenFGA, SpiceDB, OPA, Zod, Prisma, Dockerfile)
target stacks Forge does not use; the Dockerfile pack could apply to the
realm images once they are pinned (NFR-1.12). Preamble: none.

## Secure-Coding Rules

**SC-001 - Human approval for every mutation**
- **Status:** ACTIVE
- **Rule:** Code that deploys to the client, starts fixtures or peers, changes
  the realm, builds the SDK or sets up the realm MUST run only with a human
  flag (`--approve-fixtures`, `--approve-local-setup`, `--approve-build`, or
  `forge mcp --allow-fixtures`). Without it, it MUST only preview. Over MCP
  no agent input may set a flag. A shell-capable agent can pass the CLI flags
  itself; it MUST do so only with the human's standing permission and an
  announcement, and every approved live run is logged (T-001, OD-008,
  FR-6.12; log not built).
- **Enforcement:** CLI adapter; MCP `Forge.forge_run_plan`;
  `agent_workflow.run_plan`; `local_realm.setup`; `wowcontrol_build.setup`.
- **Evidence:** REQUIREMENTS.md FR-6.1, FR-11.1, FR-11.5, FR-12.3; TB-7.
- **Verification:** `test_agent_workflow.py::test_preview_does_not_mutate_or_open_wow`,
  `test_suite_tools.py::test_mcp_run_plan_requires_human_flag`,
  `test_local_realm.py::test_plan_does_not_touch_local_files_or_docker`,
  `test_wowcontrol_build.py::test_preview_is_dry_run_without_configuration`,
  `test_agent_realm.py::test_unapproved_realm_scenario_never_invokes_docker`.

**SC-002 - Confine agent paths**
- **Status:** ACTIVE
- **Rule:** Every path from an MCP call MUST resolve inside the projects
  folder; plan files MUST be `.json`. An addon or companion named by a plan
  MUST resolve inside the plan's folder.
- **Enforcement:** `mcp_server.Forge._inside`; `agent_workflow.run_plan`;
  `agent_session.run_session`.
- **Evidence:** FR-12.2; TB-1.
- **Verification:** `test_suite_tools.py::test_mcp_tools_create_check_and_spec_inside_projects`.

**SC-003 - Plans are bounded data**
- **Status:** ACTIVE
- **Rule:** A plan MUST pass the strict schema with its size limits
  (REQUIREMENTS.md FR-5.1-FR-5.3). No plan field may carry code, a shell command,
  SQL, a GM command or a file path. `slash` steps MUST name a command that the
  addon or a companion defines.
- **Enforcement:** `scenario_plan.validate_plan`, `load_plan`;
  `plan_steps.addon_slash_commands`.
- **Evidence:** FR-5.1-FR-5.7, FR-6.2; DR-6.
- **Verification:** `test_scenario_plan.py::test_reject_unsafe_or_unjudgeable_plans`,
  `test_agent_workflow.py::test_steps_are_strictly_validated`,
  `::test_steps_may_only_run_the_addons_own_slash_commands`.

**SC-004 - Fixed Lua templates, encoded values**
- **Status:** ACTIVE
- **Rule:** Lua that Forge sends to the client MUST come from a fixed template.
  Values MUST be inserted only as JSON-encoded literals (SDK) or Lua 5.1
  escaped literals (typed lines on Linux), after schema validation. Names read
  back from the client (popup names, key bindings) MUST be validated before
  they are used in Lua.
- **Enforcement:** `plan_steps._code`, `wowcontrol.bridge_run`,
  `wowcontrol.bridge_command`, `loot_scenario`; Linux typed steps (PR #14).
- **Evidence:** DR-6; TB-3.
- **Verification:** `test_suite_tools.py::test_bridge_run_sends_constant_lua_with_validated_paths`,
  `test_agent_prepare.py::test_sdk_bridge_never_accepts_non_forge_code`,
  `test_loot_scenario.py::test_unexpected_popup_name_is_never_used_in_lua`,
  `test_agent_workflow.py::test_paste_step_sets_text_only_in_a_registered_edit_box`;
  PR #14 `test_typed_steps.py::test_lua_literal_escapes_for_lua_51`.

**SC-005 - Allow-listed SDK calls to the verified client**
- **Status:** ACTIVE
- **Rule:** Forge MUST call only the allow-listed SDK methods (`client.ping`,
  `client.getScreen`, `client.getCharacters`, `client.login`,
  `client.enterWorld`, `unit.get`, `lua.evaluate`), and only over a pipe whose
  server process is the verified test-client PID. SDK replies are data; an
  unexpected screen or player string MUST NOT be shown or logged.
  Accepted risk (OD-001): the pipe keeps default ACLs, so other programs of
  the same user can also call the SDK of the test copy. Users run no untrusted
  programs during test runs.
- **Enforcement:** `wowcontrol.request` (`ALLOWED`), `wowcontrol_pipe.open_verified_pipe`.
- **Evidence:** TB-3, TB-4; `docs/qa-workflow.md` (SDK backend).
- **Verification:** `test_agent_prepare.py::test_sdk_request_rejects_unlisted_methods`,
  `::test_sdk_pipe_rejects_unknown_process`, `::test_sdk_pid_binding_mismatch_fails`,
  `::test_sdk_status_never_displays_unexpected_screen_string`.

**SC-006 - Touch only the marked test copy**
- **Status:** ACTIVE
- **Rule:** Forge MUST act only on a WoW folder with a valid
  `.addon-forge-test-copy.json` marker, and only on processes and windows
  whose executable is that copy's. It MUST NOT read, copy or change another
  installation's credentials or `WTF` data (Rising Gods). `Wow.exe` and game
  assets MAY be changed (for example SDK injection) only in the marked test
  copy, and only for an approved test workflow. Setup MUST NOT
  overwrite an existing non-Forge folder, and MUST refuse symlinks and
  overlapping source and target paths.
- **Enforcement:** `local_realm.verify_test_copy`, `make_test_copy`;
  `win_login._test_copy`; `windows_client` window lookup.
- **Evidence:** former `AGENTS.md` capability boundaries; FR-11.1.
- **Verification:** `test_win_login.py::test_refuses_unmarked_wow`,
  `test_agent_prepare.py::test_prepare_refuses_unmarked_client_on_windows`,
  `test_local_realm.py::test_copies_isolated_client_without_rising_gods_wtf`,
  `::test_existing_nonforge_folder_not_overwritten`, `::test_symlinks_refused_before_copy`,
  `::test_overlapping_paths_rejected`.

**SC-007 - Minimal keyboard input**
- **Status:** ACTIVE
- **Rule:** On Windows, typed chat MUST be limited to `/reload`, `/forge ...`
  and `/targetexact NAME` (single-line printable ASCII, at most 180
  characters). Key presses for hardware events MUST use a fixed chord that is
  unbound, and MUST restore the previous binding; an unexpected existing
  binding MUST stop the step without a press.
- **Enforcement:** `windows_client.validate_chat_command`; `plan_steps`
  hardware click; `wowcontrol.reset_idle_timer`; `loot_scenario` interact key.
- **Evidence:** FR-6.8, FR-7.3; TB-3.
- **Verification:** `test_windows_client.py::test_rejects_unsafe_commands`,
  `::test_rejected_command_never_focuses_or_types`,
  `test_agent_prepare.py::test_idle_reset_refuses_a_bound_key`,
  `test_loot_scenario.py::test_unexpected_previous_binding_never_presses_a_key`.

**SC-008 - Sandbox addon and spec code offline**
- **Status:** ACTIVE
- **Rule:** Offline addon and spec code MUST run without `os`, `io`,
  `package`, `require`, `dofile`, `loadfile`, `debug` or Python access, with
  an instruction budget (20,000,000 by default) and a 256 MB memory cap.
  Static checks MUST only compile Lua, never run it. Precompiled bytecode
  files bypass this rule today (T-004); SC-025 closes that gap.
- **Enforcement:** `headless/wow.lua` (sandbox), `headless.run_addon`;
  `lua51.syntax_error`.
- **Evidence:** NFR-1.4; TB-2.
- **Verification:** `test_offline.py::test_sandbox_blocks_host_access_and_infinite_loops`.

**SC-009 - Parse reports, never execute them**
- **Status:** ACTIVE
- **Rule:** Bridge reports MUST be read as JSON or with the strict
  SavedVariables subset parser (no code execution, limited nesting and table
  size). A report MUST match the run ID and bridge v3, or the run is
  `infrastructure_error`.
- **Enforcement:** `reports.parse_report`; `runner.judge`;
  `agent_workflow.run_plan`.
- **Evidence:** FR-6.5, FR-6.6; TB-5; DR-7.
- **Verification:** `test_reports.py::test_no_arbitrary_lua_execution`,
  `::test_limits_and_string_unescape`,
  `test_agent_workflow.py::test_old_bridge_report_is_infrastructure_error`.

**SC-010 - A passive test bridge**
- **Status:** ACTIVE
- **Rule:** The bridge MUST NOT use files or the network beyond its own
  SavedVariables (the Linux report transport), MUST run
  only registered suites, and MUST cap captured errors and report size. It is
  for the test copy only.
- **Enforcement:** `wow/ForgeTestBridge/Core.lua`.
- **Evidence:** FR-8.x; `README.md` (Deploy the bridge).
- **Verification:** `test_reports.py::test_bridge_source_contains_telemetry_contract`;
  `wow/ForgeTestBridge/tests/bridge.spec.lua`.

**SC-011 - Credentials only in the OS vault**
- **Status:** ACTIVE
- **Rule:** Realm account passwords MUST be stored only in Windows Credential
  Manager or the Linux Secret Service (plaintext keyrings refused). They MUST
  NOT appear in command-line arguments, logs, error messages, files, Git or
  shell history. Generated member passwords MUST NOT be shown. The SDK login
  MUST receive them only over the PID-verified pipe; the Linux login MUST type
  them through standard input only. Fixture children MAY get a password only
  through their environment.
- **Enforcement:** `win_login`, `local_account`, `wowcontrol.launch_and_enter`;
  Linux `client.login` (PR #14).
- **Evidence:** FR-10.7, FR-11.3, FR-11.11.
- **Verification:** `test_win_login.py::test_password_saved_only_to_vault`,
  `::test_missing_vault_entry_fails_closed`,
  `::test_member_account_fixture_gets_the_password_only_by_environment`,
  `::test_failed_member_fixture_saves_nothing_and_redacts`,
  `test_local_account.py::test_account_create_password_is_not_in_command_arguments`,
  `::test_no_plaintext_password_errors`,
  `test_agent_prepare.py::test_sdk_login_pins_rpc_to_test_pid_and_never_uses_secret_in_argv`;
  PR #14 `test_win_login.py::test_vault_refuses_plaintext_backends_on_linux`,
  `test_typed_steps.py::test_login_types_the_vault_password_through_stdin_only`.

**SC-012 - Loopback-only realm**
- **Status:** ACTIVE
- **Rule:** Every published realm port (database, auth, world) MUST bind
  to `127.0.0.1`. The realm `.env` MUST be private (mode 0600) and MUST NOT be
  overwritten or reused when it is insecure. On Linux, only the current user's
  rootless Docker socket counts as local.
- **Enforcement:** `local_realm.ensure_local_env`, `check_compose`;
  `scripts/ci/check_compose.py`.
- **Evidence:** former `AGENTS.md` capability boundaries; TB-6.
- **Verification:** `test_local_realm.py::test_local_env_private_and_loopback_only`,
  `::test_compose_rejects_exposed_public_bindings`,
  `::test_existing_insecure_env_rejected_not_overwritten`,
  `test_ci_compose.py::test_rejects_exposed_realm_port`;
  PR #14 `test_local_realm.py::test_rootless_socket_of_this_user_counts_as_local`.

**SC-013 - Never destroy realm data**
- **Status:** ACTIVE
- **Rule:** Forge MUST NOT run `docker compose down -v`, `docker volume rm`,
  MySQL `TRUNCATE`, or reset existing credentials. It MUST refuse to create
  new database credentials over an unknown existing volume. `start` MUST NOT
  rebuild images or remove volumes.
- **Enforcement:** `db_guard`, `local_realm.start_existing`.
- **Evidence:** FR-11.2.
- **Verification:** `test_local_realm.py::test_unknown_database_volume_blocks_password_creation`,
  `::test_resume_uses_no_build_and_preserves_volumes`,
  `::test_db_health_authentication_mismatch_fails_without_passwords`.

**SC-014 - Fixed fixtures only**
- **Status:** ACTIVE
- **Rule:** Realm changes MUST come only from the named, reviewed Go tests in
  `agent_scenarios/` or the upstream smoke tests (FR-10.6). GM commands and
  SQL live in those tests, never in plans or agent input. The bot obeys only
  the fixed command-file actions (`roll`, `open_trade`, `accept_trade`).
  Fixture logs MUST redact passwords; soft passes MUST be disabled.
  Fixtures use the MySQL `root` account of the loopback realm (accepted risk,
  OD-003). Plans MUST
  NOT carry server Lua: mod-ale scripts become named fixtures (FR-10.9), kept
  and reviewed in this repository and copied into the realm (FR-10.13,
  OD-010; not built).
- **Enforcement:** `agent_realm.SCENARIOS`; `loot_scenario.FixturePeer`;
  `peer_scenario._fixture_env`; plan schema (`FIXTURES`).
- **Evidence:** FR-10.x; ARCHITECTURE.md AQ-3.
- **Verification:** `test_agent_realm.py::test_unrecognized_scenarios_refused`,
  `::test_fixture_uses_upstream_fixed_go_test_and_redacts_password`,
  `test_peer_scenario.py::test_peer_environment_is_local_only_and_no_soft_pass`,
  `test_loot_scenario.py::test_fixture_peer_reports_an_exited_fixture_and_rejects_bad_names`.

**SC-015 - Warden off only by opt-in**
- **Status:** ACTIVE
- **Rule:** Warden MAY be disabled only through the explicit
  `--disable-warden-for-fixtures` setup flag, written to Forge's own compose
  override for the loopback test realm.
- **Enforcement:** `local_realm` compose override (PR #14).
- **Evidence:** FR-11.11.
- **Verification:** PR #14 `test_local_realm.py::test_compose_override_for_rootless_docker_and_opt_in_warden`.

**SC-016 - Deploy only valid addon files**
- **Status:** ACTIVE
- **Rule:** Deploy MUST refuse invalid addons, symlinks, TOC entries that
  leave the addon folder, and targets outside `Interface/AddOns`. It MUST
  stage, keep a backup and roll back on failure, and MUST NOT copy `tests/`
  or `.forge-runs/`.
- **Enforcement:** `deploy.deploy`; `validate.read_toc`.
- **Evidence:** FR-9.x, FR-2.1.
- **Verification:** `test_validate.py::test_reject_toc_traversal`,
  `test_deploy.py::test_deploy_and_replace`,
  `test_offline.py::test_spec_files_are_not_deployed_or_loaded`.

**SC-017 - Treat the SDK as untrusted third-party code**
- **Status:** ACTIVE
- **Rule:** The SDK MUST be built only from the pinned upstream commit plus
  the reviewed Forge patch, only with `--approve-build`, in a workspace
  outside the WoW folder and Git. Missing build tools MUST NOT be downloaded
  unless the user opts in (`--install-prereqs`, winget).
- **Enforcement:** `wowcontrol_build.setup`; `tools/wowcontrol-sdk/`.
- **Evidence:** FR-11.5; TB-4.
- **Verification:** `test_wowcontrol_build.py::test_approved_build_rejects_external_workspaces`,
  `::test_missing_tools_does_not_download_or_build`,
  `::test_opt_in_winget_only_for_missing_packages`,
  `::test_signed_architecture_is_checked`.

**SC-018 - Keep private data out of Git and AI providers**
- **Status:** ACTIVE
- **Rule:** Client files, game assets, `forge.toml`, `forge.local.toml`,
  `wow/api/`, `.forge-tools/` (SDK, decompilation index, Codex data),
  `.forge-runs/` evidence and credentials MUST NOT be committed. Agents MUST
  NOT upload client files, secrets, account data or screenshots of login
  screens to an AI provider.
- **Enforcement:** `.gitignore`. The upload part is an instruction to agents
  (this file, imported by `AGENTS.md`), without a technical block (accepted,
  OD-006).
- **Evidence:** former `AGENTS.md` capability boundaries; `docs/agent-playbook.md` (Codex data has no
  licence).
- **Verification:** `git check-ignore` on each path; manual review of every
  commit.

**SC-019 - Untrusted text in addons built with Forge**
- **Status:** ACTIVE
- **Rule:** An addon MUST treat chat, addon messages and pasted import strings
  as untrusted: take the sender from the event, never from the payload;
  validate every field and bound its length; drop malformed messages; never
  run received text as code; and strip or escape `|` before showing received
  text (it starts texture, color and link escapes). Shared state (for example
  RaidLedger's ledger) MUST accept changes only from senders the addon trusts
  (RaidLedger: its editor list).
- **Enforcement:** each addon's message and import handlers; its offline
  specs.
- **Evidence:** DESIGN.md (Do's and Don'ts); RaidLedger `Access.lua` (editor
  list, decided 2026-10-19); `;`-separated exchange formats.
- **Verification:** every message kind and import format an addon accepts
  MUST have an offline spec that feeds a malformed input and one that feeds an
  input from an unauthorized sender, each expecting no state change.
  `forge check` MUST fail when one is missing (OD-007, REQUIREMENTS.md
  FR-14.6, not built).

**SC-020 - Release only what passed**
- **Status:** PLANNED
- **Rule:** `forge release` MUST run every acceptance plan of the addon live
  on exactly the files it releases, and copy the addon only when all pass. It
  MUST NOT trust earlier result files (OD-011). It MUST leave out `tests/`,
  `.forge-runs/` and the test bridge, and MUST NOT push. Passing runs are
  the whole gate; no human review step is required (OD-002).
- **Enforcement:** `forge release` (not built).
- **Evidence:** FR-15.1-FR-15.3; ARCHITECTURE.md AQ-4; T-023, T-024.
- **Verification:** unit tests for the release command: a failing plan, or a
  file changed after the run, must stop the release; old result files must be
  ignored.

**SC-021 - Close only the marked client; bound the session**
- **Status:** PLANNED
- **Rule:** A session MAY close a running WoW process only when its
  executable is the marked test copy's, and MUST stop after 10 minutes.
- **Enforcement:** `agent_session.run_session` (not built).
- **Evidence:** FR-7.6, FR-7.7.
- **Verification:** unit tests with a second, unmarked WoW process that must
  survive.

**SC-022 - MCP session tool behind the human flag**
- **Status:** PLANNED
- **Rule:** `forge_session` MUST return `not_authorized` unless the human
  started the server with `--allow-fixtures`, and MUST confine its plan path
  like SC-002.
- **Enforcement:** `mcp_server` (not built).
- **Evidence:** FR-12.5.
- **Verification:** a test like `test_mcp_run_plan_requires_human_flag`.

**SC-023 - Pinned realm images**
- **Status:** PLANNED
- **Rule:** The realm MUST use AzerothCore images pinned by digest
  (`image@sha256:...`) and a mod-ale build pinned by git commit plus its exact
  build arguments. Changing a pin MUST be an explicit commit.
- **Enforcement:** `local_realm` setup (not built).
- **Evidence:** NFR-1.12; OD-004.
- **Verification:** a test that rejects a compose file or override naming an
  image without a digest.

**SC-024 - No SOAP console**
- **Status:** PLANNED
- **Rule:** Realm setup MUST NOT publish the worldserver SOAP port, and Forge
  MUST NOT use SOAP.
- **Enforcement:** `local_realm` compose checks (not built).
- **Evidence:** OD-005; ARCHITECTURE.md AQ-3.
- **Verification:** `check_compose` rejects a published SOAP port; a test like
  `test_local_realm.py::test_compose_rejects_exposed_public_bindings`.

**SC-025 - Source code only**
- **Status:** PLANNED
- **Rule:** Forge MUST refuse addon and spec files that hold precompiled Lua
  bytecode: `forge check` reports them as errors (so deploy refuses them), and
  the offline emulator does not load them.
- **Enforcement:** `validate.check_addon`; `headless/wow.lua` file and spec
  loaders (not built).
- **Evidence:** T-004; FR-2.9, FR-4.11.
- **Verification:** a test addon whose `Core.lua` is a `string.dump` chunk
  fails `forge check` and does not run in `forge spec`.

**SC-026 - Addons leave the test bridge alone**
- **Status:** PLANNED
- **Rule:** Addon code MUST NOT change the test bridge beyond calling
  `RegisterFrame` and `RegisterTest`, and MUST NOT replace the Lua error
  handler; `forge check` reports both as errors. The judge MUST attribute Lua
  errors by their source location, not by message text.
- **Enforcement:** `validate.check_addon`; the bridge's error capture and
  `scenario_plan.split_errors` (not built).
- **Evidence:** T-013; OD-009; FR-2.10, FR-6.13.
- **Verification:** test addons that overwrite a bridge function, call
  `seterrorhandler`, or raise an error naming another addon's file are
  rejected or judged as owned.

## Open Security Decisions

None. Answered on 2026-10-21:

- **OD-001** Accepted: the SDK pipe keeps default ACLs on the user's own
  machine (SC-005).
- **OD-002** Answered: passing live runs are the release gate; no human review
  step (SC-020).
- **OD-003** Accepted: fixtures keep the loopback realm's MySQL `root`
  account (SC-014).
- **OD-004** Answered: images pinned by digest, mod-ale by commit and build
  arguments (SC-023).
- **OD-005** Answered: close the SOAP port (SC-024).
- **OD-006** Accepted: the AI upload rule stays an instruction (SC-018).
- **OD-007** Answered: every message kind and import format needs malformed
  and unauthorized specs, enforced by `forge check` (SC-019, FR-14.6).
- **OD-008** Answered: keep the standing-permission model, and log every
  approved live run (SC-001, FR-6.12).
- **OD-009** Answered: `forge check` rejects addon code that tampers with the
  bridge or the error handler, and errors are attributed by source location
  (SC-026, FR-2.10, FR-6.13).
- **OD-010** Answered: fixture server Lua lives in this repository and is
  copied into the realm (SC-014, FR-10.13).
- **OD-011** Answered: `forge release` re-runs every plan live instead of
  trusting result files (SC-020, FR-15.2).
