# Addon Forge Requirements

This file owns WHAT Addon Forge must do. It was written from the existing code,
tests and docs (step A1 of [docs/spec-driven.md](docs/spec-driven.md)).

Each requirement has a status and evidence:

- `IMPLEMENTED`: code and an automated test show the behaviour. "Live" adds a
  recorded real-client run.
- `PARTIAL`: some of the behaviour exists, or it exists without a test or a
  live run.
- `NOT IMPLEMENTED`: a stated goal or user decision with no code yet.
- `TO BE REMOVED`: code exists, but the user decided to drop it. The ID stays
  so references still resolve.
- `DEFERRED`: wanted, but not now.

Test evidence is `file::test` under `tests/`. All tests on `main` passed on
2026-10-20 (293 passed, 2 skipped). Evidence marked "PR #14" is on the
unmerged branch `pull/14/head` (Linux headless runs, verified live on NixOS on
2026-10-20); the user will merge it. Decisions marked "decided 2026-10-20" come
from the first question pass (step A9). Secure-coding controls (credential
handling, sandbox limits, loopback-only binding, input validation) are in
`SECURITY.md`. This file states only the behaviour that users can see.

## Required Requirement Inputs

- Project purpose: Give a human or an AI agent a short, verifiable loop to
  build World of Warcraft 3.3.5a (build 12340) addons: create, check
  statically, test offline, and accept in a real test client.
- Primary users / actors: Addon developer (human: the owner and a few friends
  who make addons, on their own PCs); AI coding agent (through the
  MCP server or the CLI); human operator who owns the test client, the test
  realm and every approval; the AzerothCore test realm; AzerothGhost peer and
  fixture bots; the WoW 3.3.5a test client with the WoWControlSDK.
- Core workflows: create addon -> static check -> offline specs -> plan
  preview -> approved live acceptance run (`agent session` or `run-plan`) ->
  repair; set up the local realm and the test client; look up 3.3.5a APIs.
- Business objects / data entities: addon folder (`.toc`, Lua, XML,
  SavedVariables); offline spec (`tests/*.spec.lua`); acceptance plan (JSON);
  diagnostics; offline spec result; bridge report (snapshot); run result and
  evidence (`.forge-runs/`); 3.3.5a API data (client dump, decompilation
  index, Codex reference); test credentials (in Windows Credential Manager);
  `forge.toml` / `forge.local.toml`.
- External integrations: WoW 3.3.5a test client (`Wow.exe`); WoWControlSDK
  (external; built from a pinned commit with a Forge patch); AzerothCore
  (Docker Compose, rootful on Windows, rootless on Linux); AzerothGhost e2e
  (Go); MCP clients (OpenCode, Claude Code); Wine, Xvfb and xdotool (Linux);
  Nix (dev shell and package only); GitHub (source hosting only).
- Authentication / roles: The human operator grants real-client and realm
  mutation (`--approve-fixtures`, `forge mcp --allow-fixtures`,
  `--approve-local-setup`, `--approve-build`). Over MCP an agent cannot
  grant itself approval; an agent with a shell can pass CLI flags (THREAT_MODEL.md
  T-001, SECURITY.md OD-008). Test realm accounts: `main` and `member` credential slots, kept in
  Windows Credential Manager or the Linux Secret Service.
- Regulatory or privacy constraints: Use only an authorized private test realm
  and a legitimately owned client. Rules: `SECURITY.md` SC-006, SC-018.

## Functional Requirements

### 1. Addon scaffold (`forge new`, `forge_new`)

- **FR-1.1** The system MUST create `<root>/<Name>/` with a `.toc`
  (`## Interface: 30300`, a SavedVariables table `<Name>DB`), `Core.lua`, an
  offline spec in `tests/`, and `<root>/<Name>-acceptance.json`.
  *IMPLEMENTED: `src/addon_forge/scaffold.py`;
  `test_suite_tools.py::test_scaffold_passes_static_offline_and_plan_validation`*
- **FR-1.2** The scaffold MUST pass `forge check`, `forge spec` and plan
  validation without edits.
  *IMPLEMENTED: same test*
- **FR-1.3** The system MUST reject an addon name that does not start with a
  capital letter and have 3-40 letters or digits, and a test character name
  that is not 2-12 letters.
  *IMPLEMENTED: `scaffold.py` (`NAME`); no dedicated test*
- **FR-1.4** The system MUST refuse to overwrite an existing addon folder or
  plan file.
  *IMPLEMENTED: `scaffold.py` (`FileExistsError`); no dedicated test*

### 2. Static checks (`forge check`, `forge_check`)

- **FR-2.1** The system MUST report an error when the addon folder does not
  have exactly one top-level `.toc`, when `## Interface` is not `30300`, when
  a TOC entry is missing, or when a TOC entry leaves the addon folder.
  *IMPLEMENTED: `validate.py`; `test_validate.py::test_bad_interface_and_missing_file`,
  `::test_reject_toc_traversal`*
- **FR-2.2** The system MUST follow XML `<Script file>` and `<Include file>`
  entries in TOC load order, and report malformed XML and missing referenced
  files.
  *IMPLEMENTED: `validate.py::_xml_lua_files`; no dedicated test*
- **FR-2.3** The system MUST compile every Lua file with Lua 5.1 and report
  Lua 5.2+ syntax as an error with file and line.
  *IMPLEMENTED: `lua51.py`; `test_offline.py::test_lua52_syntax_is_rejected`*
- **FR-2.4** The system MUST report, with file:line and a 3.3.5a replacement
  hint, each use of a known-absent global, widget method or Lua 5.2 library
  field.
  *IMPLEMENTED: `test_offline.py::test_static_check_flags_modern_and_lua52_apis`,
  `::test_bytecode_reports_globals_fields_and_methods_with_lines`*
- **FR-2.5** When a 3.3.5a client global dump exists, the system MUST warn
  about each global the addon reads that is neither in the dump, defined by
  the addon, nor a Lua 5.1 global. Without a dump it MUST say that coverage is
  limited.
  *IMPLEMENTED: `test_offline.py::test_unknown_global_needs_client_dump`*
- **FR-2.6** The system MUST warn about Lua files the TOC does not load (except
  under `tests/` and `.forge-runs/`) and about short lowercase global
  assignments that are probably a missing `local`.
  *IMPLEMENTED: `validate.py`; no dedicated test*
- **FR-2.7** The system MUST report symlinked Lua files as errors.
  *IMPLEMENTED: `validate.py`; no dedicated test*
- **FR-2.8** `forge check` MUST exit 0 when there are no errors and 1
  otherwise, and MUST say that passing does not prove in-client correctness.
  *IMPLEMENTED: `cli.py`; `test_offline.py::test_static_check_accepts_real_addons`*
- **FR-2.9** `forge check` MUST report a Lua file that holds precompiled Lua
  bytecode instead of source as an error, so deploy refuses it too.
  *NOT IMPLEMENTED: THREAT_MODEL.md T-004 (a bytecode `Core.lua` passed on
  2026-10-21)*
- **FR-2.10** `forge check` MUST report an error when addon code changes the
  test bridge other than by calling `RegisterFrame` or `RegisterTest`, or
  replaces the Lua error handler (`seterrorhandler`).
  *NOT IMPLEMENTED: decided 2026-10-21 (SECURITY.md OD-009, THREAT_MODEL.md
  T-013)*
- **FR-2.11** `forge check` MUST fail when a named top-level window of the
  addon (a frame created with `UIParent` as its parent) has no offline spec
  that fills it with full data and calls `forge.layoutIssues` on it.
  *NOT IMPLEMENTED: decided 2026-10-21 (second question pass) (DESIGN.md readability rules)*

### 3. 3.3.5a API knowledge (`forge api`, `forge_api_lookup`)

- **FR-3.1** For a global, `Widget:Method` or event name, lookup MUST answer
  `exists` true, false or unknown, with its source (client dump, local 12340
  decompilation, built-in list, Codex) and a hint for absent APIs.
  *IMPLEMENTED: `wowapi.py::lookup`;
  `test_suite_tools.py::test_lookup_uses_local_decompiled_client_registrations`,
  `::test_local_12340_decompilation_answers_native_apis_without_a_client_dump`*
- **FR-3.2** When local Codex data is present, lookup MUST add signatures and
  event payloads, and Codex data MUST NOT overrule a known-absent API.
  *IMPLEMENTED: `test_suite_tools.py::test_lookup_attaches_codex_signatures_and_payloads`,
  `::test_codex_never_overrules_known_absent_apis`,
  `::test_lookup_without_codex_data_is_unchanged`*
- **FR-3.3** `forge api lookup` MUST exit 1 when any name is known to be absent.
  *IMPLEMENTED: `cli.py`; no dedicated test*
- **FR-3.4** `forge api dump` MUST record the in-world test client's `_G` keys
  and widget methods in `wow/api/`, and MUST refuse when the client is not in
  the world.
  *IMPLEMENTED (live: 33,826 globals, 2,261 methods):
  `test_suite_tools.py::test_api_dump_reassembles_chunks_and_fits_the_pipe`,
  `::test_api_dump_refuses_outside_world`*
- **FR-3.5** The MCP lookup tool MUST accept at most 50 names per call.
  *IMPLEMENTED: `mcp_server.py`; no dedicated test*
- **FR-3.6** `forge api dump` MUST also record the font file and size of the
  client's standard font objects (for example `GameFontNormal`), and offline
  text sizes MUST use them when present.
  *NOT IMPLEMENTED: decided 2026-10-20 (DESIGN.md DQ-2)*

### 4. Offline specs (`forge spec`, `forge_spec`)

- **FR-4.1** The system MUST load the addon in a headless 3.3.5a emulation in
  real client order (TOC order, XML scripts inlined, SavedVariables after the
  files, `ADDON_LOADED`, `PLAYER_LOGIN`).
  *IMPLEMENTED: `test_offline.py::test_saved_variables_load_after_files_like_the_client`*
- **FR-4.2** The system MUST run a load-only smoke run plus each
  `tests/*.spec.lua`. Each spec file MUST get a fresh world; tests in one file
  share state in order.
  *IMPLEMENTED: `headless/__init__.py::run_specs`*
- **FR-4.3** Specs MUST be able to drive and observe the emulated client
  through the `forge` table (events, time, slash commands, clicks, hardware
  clicks, typing, units, party, raid, items, loot, rolls, combat, chat, addon
  messages, bags, guild, calendar, trade, tooltips, popups, SavedVariables,
  `/reload`, stubs) and assert with `expect()` matchers.
  *IMPLEMENTED: `headless/wow.lua`; `README.md` (harness API);
  `test_offline.py::test_forge_loot_ledger_reference_addon_passes_all_specs`*
- **FR-4.4** The emulation MUST follow the audited 12340 client behaviour:
  OnUpdate only for visible frames, OnShow/OnHide on visibility changes,
  FontString text rules, and events the client lacks never delivered.
  *IMPLEMENTED: `test_offline.py::test_emulation_matches_the_audited_client_behaviour`,
  `::test_onupdate_runs_only_for_visible_frames`,
  `::test_events_the_client_lacks_are_ignored_and_reported`,
  `::test_decompiled_event_table_blocks_unlisted_events_in_offline_addon_specs`*
- **FR-4.5** The system MUST report each global, widget method, event and
  template that the emulation does not model: an error when it is known absent
  from 3.3.5a, a warning when it is missing from the client dump, and
  otherwise info that suggests `forge.stub`.
  *IMPLEMENTED: `headless/__init__.py::_classify`;
  `test_offline.py::test_client_method_dump_makes_missing_widget_methods_fail_like_the_client`,
  `::test_feature_detection_read_of_missing_method_is_not_an_error`*
- **FR-4.6** A load error, a runtime error, a failed test or an error
  diagnostic MUST fail the run; failures MUST NOT be hidden.
  *IMPLEMENTED: `test_offline.py::test_failures_are_reported_not_hidden`,
  `::test_load_error_and_modern_api_call_fail_the_run`*
- **FR-4.7** `forge.layoutIssues(frame)` MUST report overlapping and
  overflowing regions, using estimated text widths.
  *IMPLEMENTED (fix confirmed live by screenshot):
  `test_offline.py::test_layout_check_finds_overlap_overflow_and_respects_explicit_lines`*
- **FR-4.8** `forge.sketch(name, frame)` MUST save an SVG drawing of the frame
  to `.forge-runs/sketches/<Addon>-<name>.svg` beside the addon.
  *IMPLEMENTED: `test_offline.py::test_sketch_saves_an_svg_of_what_a_window_draws`*
- **FR-4.9** Spec files MUST NOT be loaded by the addon or deployed to the
  client.
  *IMPLEMENTED: `test_offline.py::test_spec_files_are_not_deployed_or_loaded`*
- **FR-4.10** `forge spec` MUST exit 0 only when every run passed, print a
  per-test summary, and print the full result with `--json`.
  *IMPLEMENTED: `cli.py`; no dedicated test*
- **FR-4.13** The emulation MUST model frame size and scale like the 12340
  client: `StartMoving`/`StartSizing` fail unless the frame is movable or
  resizable; `forge.drag(frame, dx, dy)` moves the frame that started moving,
  or sizes the one that started sizing within its `Min/MaxResize`;
  `OnSizeChanged` runs on the next frame, only when the size changed (also
  after `SetScale`; the scale reads back as a 32-bit float); a frame
  without its own size reports the size of its
  anchors; and `SetScale` scales a frame and its children on screen, so
  `forge.layoutIssues` sees a scaled window that leaves the screen.
  *IMPLEMENTED: `headless/wow.lua`;
  `tests/emulation/ClientFidelity/tests/size.spec.lua` (run by
  `test_offline.py::test_emulation_matches_the_audited_client_behaviour`)*
- **FR-4.14** The emulation MUST model the client's item cache: an item a
  spec declares with `forge.item(id, { cached = false })` gives no
  `GetItemInfo` answer, and asking again does not change that; showing it in
  a tooltip shows `RETRIEVING_ITEM_INFO` and caches it on a later frame; a
  looted item is cached. No event announces it (3.3.5a has none).
  *IMPLEMENTED: `headless/wow.lua`; `tests/emulation/ClientFidelity/tests/items.spec.lua`
  (live: RaidWishlist's hidden tooltip fetched never-seen item 20514,
  run `1e0dd41331cf`)*
- **FR-4.12** `forge spec` MUST run every spec file once in a deDE and once in
  an enUS world, and a spec passes only when it passes in both. Specs MUST NOT
  assert exact locale-specific words; they compare against the addon's own
  text keys or the client's GlobalStrings.
  *NOT IMPLEMENTED: decided 2026-10-21 (second question pass); existing RaidLedger and RaidWishlist specs that
  assert German words need rewriting*
- **FR-4.11** The offline emulator MUST refuse to load addon or spec files
  that hold precompiled Lua bytecode, and report a load error.
  *NOT IMPLEMENTED: THREAT_MODEL.md T-004 (such a file loaded and ran on
  2026-10-21)*

### 5. Acceptance plans (schema)

- **FR-5.1** The system MUST accept only version 1 plans with `addon`,
  `character`, `peers` (0-4) and 1-20 `checks`, plus the optional `observer`,
  `fixtures`, `steps`, `companions`, `member` and `member_addons`. It MUST
  reject unknown keys, duplicate checks and files over 20,000 bytes.
  *IMPLEMENTED: `scenario_plan.py::validate_plan`;
  `test_scenario_plan.py::test_validation_accepts_bounded_plan`,
  `::test_reject_unsafe_or_unjudgeable_plans`*
- **FR-5.2** The system MUST support exactly these check types, each with an
  exact key set: `frame_visible`, `frame_text_contains`, `global_equals`
  (dotted path, at most 10 per client), `chat_contains`, `event_fired`,
  `no_lua_errors`, `player_in_world`, `target_player` (needs a peer) and
  `party_count_at_least` (0-4).
  *IMPLEMENTED: `test_agent_workflow.py::test_new_checks_are_strict_about_keys_and_values`*
- **FR-5.3** The system MUST support at most 20 steps with at most 180 s of
  waiting in total: `slash`, `roll` and `peer_roll` (1 <= low <= high <= 10000),
  `wait` (0-60 s), `click`, `hardware_click`, `paste` (registered edit box,
  1-1000 printable ASCII characters without `|`), `screenshot`,
  `peer_trade` (item ID) and `peer_say` (`[text]` or `[text, item ID]`; the
  text is 1-60 characters, starts with a letter and holds only letters,
  digits, spaces and `, . : ! ? ' -`).
  *IMPLEMENTED (`peer_say` live: session `d26c83592992`, bridge run `4b80e79fb9ad`, 2026-10-26):
  `test_agent_workflow.py::test_steps_are_strictly_validated`,
  `::test_peer_say_steps_are_validated`,
  `::test_peer_and_screenshot_steps_are_validated`,
  `::test_companions_and_paste_steps_are_validated`,
  `::test_hardware_click_steps_are_validated`*
- **FR-5.4** The system MUST support the fixtures `master_loot`, `raid_lead`
  and `boe_loot`. `raid_lead` and `boe_loot` MUST require `master_loot`.
  Fixtures and steps MUST require the bridge observer, and fixtures MUST
  require `peers` = 0, except the planned `party` fixture (FR-10.11). `peer_roll`, `peer_trade` and `peer_say` MUST require
  `master_loot`.
  *IMPLEMENTED: `test_agent_workflow.py::test_raid_lead_fixture_extends_master_loot`,
  `::test_boe_loot_fixture_extends_master_loot`*
- **FR-5.5** A plan MAY list up to 3 companion addons beside the plan; they
  are checked, tested offline and deployed with the addon, and their slash
  commands MAY be used in steps.
  *IMPLEMENTED: `test_agent_workflow.py::test_companion_slash_commands_may_be_used_in_steps`,
  `::test_companion_errors_count_for_the_plan`*
- **FR-5.6** A plan MAY name a second test character (`member`). Its steps and
  checks then take `"client": "member"`, `peer_*` steps MUST stay on the main
  client, and `member_addons` MAY limit the member's addons to 1-4 of the
  plan's addons.
  *IMPLEMENTED: `test_agent_workflow.py::test_two_player_plans_are_validated`,
  `::test_member_addons_are_validated`*
- **FR-5.7** An SDK-observer plan MUST allow only `player_in_world` checks with
  `peers` = 0, and MUST be rejected before any client is started.
  *IMPLEMENTED: `test_scenario_plan.py::test_sdk_only_plan_accepts_world_observation`,
  `::test_sdk_only_rejects_frame_checks_before_starting_client`,
  `::test_sdk_only_rejects_peers`*

### 6. Plan execution and judging (`agent run-plan`, `forge_plan_preview`, `forge_run_plan`)

- **FR-6.1** Without approval, the system MUST return `plan_only` with the
  validated plan and the ordered list of operations a run would perform. It
  MUST NOT deploy, start a client or touch the realm.
  *IMPLEMENTED: `test_agent_workflow.py::test_preview_does_not_mutate_or_open_wow`*
- **FR-6.2** The system MUST reject `slash` steps that call a slash command
  that neither the addon nor its companions define.
  *IMPLEMENTED: `test_agent_workflow.py::test_steps_may_only_run_the_addons_own_slash_commands`*
- **FR-6.3** With approval, the system MUST run in this order: static checks
  (every addon) -> offline specs (every addon) -> deploy (with the bridge) ->
  fixtures -> steps -> bridge suite -> independent checks. A failing stage
  MUST stop the run and name the stage.
  *IMPLEMENTED: `agent_workflow.py::run_plan`;
  `test_agent_workflow.py::test_failing_offline_spec_stops_before_deploy`,
  `::test_failed_step_fails_the_plan_before_the_suite`*
- **FR-6.4** When a deploy changes files while a test client is running, the
  run MUST stop with `infrastructure_error` and tell the user to use
  `agent session` or restart the client.
  *IMPLEMENTED: `test_agent_workflow.py::test_changed_files_on_a_running_client_are_not_tested`,
  `::test_differs_ignores_specs_and_detects_changes`*
- **FR-6.5** The system MUST judge each check only from the bridge's
  independent snapshot, never from the addon's own assertions alone. A
  missing snapshot MUST give `infrastructure_error`.
  *IMPLEMENTED (live): `test_agent_workflow.py::test_report_success_requires_independent_snapshot`,
  `::test_no_telemetry_never_passes`;
  `test_scenario_plan.py::test_check_frame_not_reported_is_not_a_false_pass`*
- **FR-6.6** A report from a bridge other than v3 MUST give
  `infrastructure_error` with restart instructions.
  *IMPLEMENTED: `test_agent_workflow.py::test_old_bridge_report_is_infrastructure_error`*
- **FR-6.7** `no_lua_errors` MUST count errors from the addon, its companions,
  the bridge and errors with no addon path. Errors from other addons MUST be
  reported as foreign and MUST NOT fail the plan.
  *IMPLEMENTED: `test_agent_workflow.py::test_other_addons_errors_do_not_fail_this_addon`*
- **FR-6.8** Steps MUST run as fixed Lua templates over the SDK, stop at the
  first failing step, and return a step log. `hardware_click` MUST bind a
  fixed unused key to the frame, press it with real input and restore the
  previous binding, even on failure.
  *IMPLEMENTED (live): `test_agent_workflow.py::test_step_runner_sends_fixed_lua_and_stops_on_failure`,
  `::test_hardware_click_binds_presses_and_restores_the_key`,
  `::test_hardware_click_fails_without_a_click_and_still_restores`*
- **FR-6.9** In a two-player plan, the system MUST run the bridge suite on both
  clients and judge each check against its own client's report.
  *IMPLEMENTED (live, run `e79dce3d73c2`/`c92f8b278d93`):
  `test_agent_workflow.py::test_checks_are_judged_against_their_own_client_report`,
  `::test_member_steps_run_on_the_member_client`*
- **FR-6.10** Each result MUST be exactly one of: `plan_only` (preview;
  nothing tested or changed); `passed` (matching report, non-empty suite,
  every assertion and independent check passed, no owned Lua errors);
  `failed` (matching report with a failed assertion, check or owned Lua error,
  or a failed gate stage); `infrastructure_error` (no reliable correlated
  evidence, for example an unreachable client, an old bridge or no report; no
  conclusion about the addon). The CLI MUST exit 0 only for `plan_only` and
  `passed`.
  *IMPLEMENTED: `cli.py`; `docs/qa-workflow.md` (Interpreting test outcomes)*
- **FR-6.11** The system MUST store evidence (result JSON, end screenshot,
  `screenshot` step images, fixture logs) in `.forge-runs/` beside the plan.
  *IMPLEMENTED (live): `test_agent_workflow.py::test_screenshot_step_saves_under_its_name`*
- **FR-6.12** Every approved live run (`run-plan`, `session`, `forge_run_plan`,
  `forge_session`, `release`) MUST append one entry to a run log: time, entry
  point (CLI or MCP), plan, content hash of the plan's addons, run IDs and
  outcome. The log is `.forge-runs/run-log.jsonl` beside the plan (not in
  Git).
  *NOT IMPLEMENTED: decided 2026-10-21 (SECURITY.md OD-008, THREAT_MODEL.md
  T-001)*
- **FR-6.13** The judge MUST attribute captured Lua errors to an addon by
  where they were raised (the bridge records the error's source location), not
  by file names in the message text.
  *NOT IMPLEMENTED: decided 2026-10-21 (SECURITY.md OD-009, THREAT_MODEL.md
  T-013); needs a bridge report change (ARCHITECTURE.md DR-7)*

### 7. Live sessions (`agent session`, `agent prepare`)

- **FR-7.1** `agent session PLAN --approve-fixtures` MUST check the plan's
  addons, deploy them before starting the client, start the marked test
  client, log in through the SDK with vault credentials, enter the plan's
  character, and then run the plan.
  *IMPLEMENTED (live): `agent_session.py`;
  `test_agent_prepare.py::test_session_preview_no_client_or_credentials`*
- **FR-7.6** When the marked test client is already running, the session MUST
  close it before deploying, and MUST NOT close any other WoW process (the
  process path decides).
  *IMPLEMENTED (live: a second session closed the first one's client, run
  `eb2de9a7d59b`): `windows_client.close_test_clients` (WM_CLOSE, then end the
  process after re-checking its executable), called by `agent_session.run_session`;
  `test_agent_prepare.py::test_close_test_clients_closes_only_the_marked_copy`,
  `::test_close_test_clients_terminates_a_client_that_ignores_close`,
  `::test_close_test_clients_never_terminates_a_process_that_changed_executable`,
  `::test_session_closes_a_running_test_client_before_deploying`*
- **FR-7.7** A session MUST stop after 10 minutes with `infrastructure_error`
  and release the desktop.
  *NOT IMPLEMENTED: decided 2026-10-20*
- **FR-7.2** For a two-player plan the session MUST start a second client with
  the `member` credentials, write the member's addon selection when
  `member_addons` is set, and fail as `infrastructure_error` when the member
  does not enter the world.
  *IMPLEMENTED (live, run `a70a09025c67`):
  `test_agent_prepare.py::test_member_client_starts_next_to_main_with_member_credentials`,
  `test_agent_workflow.py::test_member_character_loads_only_the_chosen_addons`*
- **FR-7.3** After login, the session MUST prevent the client's idle logout
  with one press of an unbound key, and MUST refuse when that key is bound.
  *IMPLEMENTED (live): `test_agent_prepare.py::test_idle_reset_presses_only_an_unbound_key_and_cancels_camp`,
  `::test_idle_reset_refuses_a_bound_key`*
- **FR-7.4** The session MUST verify that the world identity matches the
  plan's character (two stable matches) before it runs the plan.
  *IMPLEMENTED: `test_agent_prepare.py::test_world_identity_requires_two_unit_matches_without_lua`
  and related tests*
- **FR-7.5** Sessions MUST run on native Windows with the `wowcontrol`
  backend, and on Linux with the headless `xdotool` backend (FR-11.9).
  *PARTIAL: Windows IMPLEMENTED (`agent_session.py`). On Linux, PR #14 runs
  `client headless`, `client login enter` and `run-plan` as separate commands;
  `agent session` there is NOT IMPLEMENTED*

### 8. In-client test bridge (`wow/ForgeTestBridge`)

- **FR-8.1** The bridge MUST let addons register test functions
  (`RegisterTest`) and observable frames (`RegisterFrame`, names up to 32
  word characters), and MUST run a named suite on request.
  *IMPLEMENTED (live): `wow/ForgeTestBridge/Core.lua`;
  `wow/ForgeTestBridge/tests/bridge.spec.lua`*
- **FR-8.2** The bridge report MUST contain the run ID, the bridge and schema
  version, test results, captured Lua errors (each distinct message once, with
  a count, at most 50) and a snapshot: player, target, party or raid,
  registered frames (shown, size, text), recent chat, event counts and watched
  globals.
  *IMPLEMENTED (live): `test_reports.py::test_parse_versioned_bridge_snapshot`,
  `::test_bridge_source_contains_telemetry_contract`*
- **FR-8.3** The bridge MUST return its report as JSON in the same SDK call
  (Windows) or through SavedVariables after `/reload` (Linux). On Linux,
  `/forge watch PATH` MUST tell the bridge which globals to report.
  *IMPLEMENTED (live on both; Linux in PR #14):
  `test_suite_tools.py::test_bridge_run_sends_constant_lua_with_validated_paths`,
  `test_reports.py::test_parse_savedvariables`*
- **FR-8.4** The bridge report MUST stay below about 28 KB, dropping chat, then
  error counts, then events.
  *IMPLEMENTED: `docs/agent-playbook.md` (Test-environment facts); no dedicated test*

### 9. Deploy (`forge deploy`)

- **FR-9.1** The system MUST deploy only a valid addon into
  `<wow_dir>/Interface/AddOns/<Name>`, excluding `tests/`, `.forge-runs/`,
  `.git` and caches, replace the old copy, and roll back on failure.
  *IMPLEMENTED: `deploy.py`; `test_deploy.py::test_deploy_and_replace`*
- **FR-9.2** The system MUST refuse to deploy when the addon contains symlinks
  or the target folder has no `Wow.exe`.
  *IMPLEMENTED: `deploy.py`; no dedicated test*

### 10. Realm fixtures and peers

- **FR-10.1** `master_loot` MUST spawn a creature near the graphical character,
  kill it, form a party with a bot under master loot, open the real loot
  window on the client, and hold it open for the plan. Afterwards it MUST
  remove the creature and the party.
  *IMPLEMENTED (live): `loot_scenario.py`, `agent_scenarios/loot_roll_test.go`;
  `test_loot_scenario.py` (20 tests)*
- **FR-10.15** The corpse that `master_loot` (and `boe_loot`) hands to the plan
  MUST hold no item at or above the master-loot threshold (uncommon) other
  than the fixture's item, so a plan's roll always lands on that item. The
  fixture's bot opens the corpse's loot before the client does; a corpse with
  another such drop is removed and a new creature killed, at most 8 times,
  after which the fixture fails as an infrastructure error.
  *IMPLEMENTED (live: session `8e4b34c58371`, bridge run `09d7022e406c`,
  2026-10-26; the bot checked the corpse and logged "holds only item 20513",
  so the re-kill branch is unit-tested only):
  `agent_scenarios/loot_check_test.go::TestOnlyTheFixtureItemReachesTheThreshold`,
  `test_loot_scenario.py::test_fixture_plan_says_the_corpse_holds_only_the_fixture_item`.
  Decided 2026-10-26 after the RaidWishlist 2.3.0 release refused: Crimson
  Templar also dropped Essence of Fire (7078) and RaidLedger rolled that.*
- **FR-10.2** `master_loot` MUST revive the graphical and member characters
  before and after the kill, and confirm that the corpse is gone from the
  world.
  *IMPLEMENTED (live): `docs/agent-playbook.md` (Test-environment facts);
  no dedicated test*
- **FR-10.3** `raid_lead` MUST make the plan's character the party leader.
  `boe_loot` MUST use a creature that always drops a bind-on-equip item.
  *IMPLEMENTED (live, runs `81bb5148cbe4`, `88000397b237`):
  `test_loot_scenario.py::test_boe_variant_describes_its_own_corpse_and_item`*
- **FR-10.4** `peer_roll` MUST make the fixture bot roll in the given range,
  and `peer_trade` MUST trade the item from the graphical character to the
  bot, with the bot listening before the trade starts.
  *IMPLEMENTED (live, runs `b2b299f6e36e`, `b1b2079d8755`):
  `test_agent_workflow.py::test_peer_trade_runs_the_trade_handshake_in_order`,
  `test_loot_scenario.py::test_fixture_peer_waits_until_the_bot_listens`*
- **FR-10.14** `peer_say` MUST make the fixture bot say the step's text in
  party chat, followed by a link to the item when the step names one. The bot
  builds the link from the realm's item data (fixed read-only query) and
  reports `unknown_item` for an item the realm lacks. The text never reaches
  the server as a command (SECURITY.md SC-014), so addons can be tested
  against roll announcements in chat (RaidWishlist FR-RW-002).
  *IMPLEMENTED (live, session `d26c83592992`, bridge run `4b80e79fb9ad`, 2026-10-26: the bot's party line arrived as
  `roll |cffa335ee|Hitem:40347:...` and opened RaidWishlist's prompt):
  `test_agent_workflow.py::test_peer_say_makes_the_fixture_bot_speak`,
  `test_loot_scenario.py::test_fixture_peer_says_only_safe_text`,
  `agent_scenarios/say_test.go::TestSayTextIsNeverACommand`*
- **FR-10.5** A plan with `peers` = 1-4 MUST run that many AzerothGhost
  protocol peers only while the client suite runs. `agent party-lifecycle`
  MUST check the client before and after the peers leave.
  *IMPLEMENTED (live for 1 and 3 peers): `test_peer_scenario.py`*
- **FR-10.6** `agent realm-fixture` MUST run only the upstream smoke tests
  `create-character`, `login-world` and `teleport`.
  *IMPLEMENTED: `test_agent_realm.py::test_unrecognized_scenarios_refused`,
  `::test_unapproved_realm_scenario_never_invokes_docker`*
- **FR-10.7** `local-realm create-member` MUST create the second test account
  and character and save the credentials in the `member` vault slot without
  showing the password.
  *IMPLEMENTED (live): `test_win_login.py::test_member_account_fixture_gets_the_password_only_by_environment`,
  `::test_failed_member_fixture_saves_nothing_and_redacts`*
- **FR-10.8** The first combat fixture MUST be a general boss fight
  (`boss_fight`): a boss with 3 phases, changing at 66% and 33% health, a
  different spell in each phase and a yell at each phase change, so that an
  addon can observe the casts and phase changes. It is not tied to one addon.
  *NOT IMPLEMENTED: decided 2026-10-20; shape decided 2026-10-21 (second question pass)*
- **FR-10.9** New server-side fixtures MUST be prototyped as server Lua
  (mod-ale) and then promoted to named, typed plan fixtures. Plans MUST NOT
  carry raw server Lua.
  *NOT IMPLEMENTED: user decision of 2026-10-20 (mod-ale is on the local
  realm, outside this repository)*
- **FR-10.10** `agent capabilities` MUST be removed; `AGENTS.md` and the MCP
  tool list describe what an agent can do.
  *TO BE REMOVED: decided 2026-10-20 (the command lists working features as
  "in progress")*
- **FR-10.11** A plan MUST be able to put the graphical test character into
  one party with 1-4 peers with `"fixtures": ["party"]` and `"peers": 1-4` (the
  one fixture allowed with peers), so that party frames and party addons can
  be tested.
  *NOT IMPLEMENTED: decided 2026-10-20. Today the peers form their own party
  (`docs/qa-workflow.md`, Verification status)*
- **FR-10.12** The system SHOULD provide a quest fixture.
  *DEFERRED: decided 2026-10-20 (combat comes first)*
- **FR-10.13** Server Lua scripts of named fixtures MUST live in this
  repository and be reviewed there. Forge MUST copy them into the realm's
  `lua_scripts` folder; that folder holds only these, plus scratch files while
  a new fixture is being written.
  *NOT IMPLEMENTED: decided 2026-10-21 (SECURITY.md OD-010, THREAT_MODEL.md
  T-018)*

### 11. Local realm and test client setup

- **FR-11.1** `local-realm setup` MUST preview its changes unless
  `--approve-local-setup` is given. With approval it MUST clone official
  AzerothCore, write a loopback-only configuration, make or adopt a separate
  WoW test copy, write `forge.local.toml` and start the realm.
  *IMPLEMENTED: `test_local_realm.py` (24 tests). Full live integration:
  `UNKNOWN` (`README.md` says it is still needed)*
- **FR-11.2** `local-realm start|status|logs|console|stop` MUST manage the
  existing containers; `start` MUST NOT rebuild images or remove volumes.
  *IMPLEMENTED: `test_local_realm.py::test_resume_uses_no_build_and_preserves_volumes`*
- **FR-11.3** `client login save` MUST store test credentials for the `main`
  or `member` slot, and only for the marked test copy.
  *IMPLEMENTED: `test_win_login.py::test_password_saved_only_to_vault`,
  `::test_refuses_unmarked_wow`, `::test_member_slot_has_its_own_vault_entry`*
- **FR-11.4** `client windowed` MUST set the test client's resolution while
  the game is closed, and keep a backup of the previous configuration.
  *IMPLEMENTED: `test_client_settings.py`*
- **FR-11.5** `agent wowcontrol-setup` MUST only preview without
  `--approve-build`. With approval it MUST build the pinned WoWControlSDK
  commit outside the WoW folder and Git, and enable the SDK backend only when
  a realm name is given.
  *IMPLEMENTED (live): `test_wowcontrol_build.py`*
- **FR-11.6** `agent wowcontrol-status` MUST read the client screen state
  without login or game input.
  *IMPLEMENTED: `test_agent_prepare.py::test_sdk_client_status_read_only_and_pid_bound`*
- **FR-11.7** `realmlist` and `tunnel` (reach a realm over SSH).
  *TO BE REMOVED: decided 2026-10-20; they existed only for the cloud realm.
  Code: `realm_connect.py`, `test_realm_connect.py`*
- **FR-11.8** `forge doctor` MUST report the tools, embedded Lua, the API dump
  state and the configured WoW and realm folders.
  *IMPLEMENTED: `cli.py`; no dedicated test*
- **FR-11.9** On Linux, `client headless` MUST start a private Xvfb display
  with GLX (`xvfb = "nix"` takes Xvfb and Mesa from one nixpkgs) and the Wine
  client on it, so nothing appears on the desktop. `client login enter` MUST
  log in with the vault credentials and enter the world.
  *IMPLEMENTED (live, PR #14):
  `test_xvfb_display.py::test_xvfb_from_nix_uses_matching_mesa_drivers`,
  `::test_headless_display_must_be_configured`,
  PR #14 `test_typed_steps.py::test_login_types_the_vault_password_through_stdin_only`*
- **FR-11.10** On Linux, plan steps MUST be typed as `/run` lines from the
  same templates as on Windows, split under the 255-character chat limit. Each
  step's result MUST become an extra plan check, and `hardware_click` MUST be
  a plain click (a typed line is already a hardware event).
  *IMPLEMENTED (live, PR #14):
  `test_typed_steps.py::test_short_step_is_one_line_and_long_step_is_chunked_within_the_chat_limit`,
  `::test_typed_run_steps_numbers_steps_and_turns_hardware_click_into_a_click`*
- **FR-11.11** On Linux, `local-realm setup` MUST accept the user's rootless
  Docker socket as local, MAY use the upstream prebuilt images
  (`--pull-images`), and MAY turn off Warden for fixtures only with
  `--disable-warden-for-fixtures`. Test credentials MUST go to the Secret
  Service, and plaintext keyrings MUST be refused.
  *IMPLEMENTED (live, PR #14):
  `test_local_realm.py::test_rootless_socket_of_this_user_counts_as_local`,
  `::test_setup_can_pull_prebuilt_images_instead_of_building`,
  `::test_compose_override_for_rootless_docker_and_opt_in_warden`,
  `test_win_login.py::test_vault_refuses_plaintext_backends_on_linux`*
- **FR-11.12** Linux MUST support the same plans as Windows: `member` (two
  clients), `peers` and the `master_loot`, `raid_lead` and `boe_loot`
  fixtures.
  *NOT IMPLEMENTED: decided 2026-10-20. PR #14 refuses these on the Linux
  backend*
- **FR-11.13** On Linux, the WoWControlSDK MUST run inside the Wine test
  client, so Linux runs use the same SDK channel as Windows (per-process pipe,
  JSON reports, fixed Lua).
  *NOT IMPLEMENTED: decided 2026-10-21 (ARCHITECTURE.md AQ-1); unknown whether
  the SDK works under Wine*

### 12. MCP server (`forge mcp`)

- **FR-12.1** The system MUST serve `forge_new`, `forge_check`, `forge_spec`,
  `forge_api_lookup`, `forge_plan_preview` and `forge_run_plan` over stdio
  MCP, with usage instructions in the `initialize` reply.
  *IMPLEMENTED: `test_suite_tools.py::test_mcp_handshake_lists_tools_and_ignores_notifications`*
- **FR-12.2** Every MCP path argument MUST stay inside the projects folder.
  *IMPLEMENTED: `test_suite_tools.py::test_mcp_tools_create_check_and_spec_inside_projects`*
- **FR-12.3** `forge_run_plan` MUST return `not_authorized` unless the human
  started the server with `--allow-fixtures`.
  *IMPLEMENTED: `test_suite_tools.py::test_mcp_run_plan_requires_human_flag`*
- **FR-12.4** A tool failure MUST return `isError` with the message, and tools
  MUST NOT write to the protocol stream.
  *IMPLEMENTED: `mcp_server.py::handle`; no dedicated test*
- **FR-12.5** The MCP server MUST offer `forge_session`, which runs
  `agent session` (FR-7.1) for a plan under the projects folder, and only when
  the human started the server with `--allow-fixtures`.
  *NOT IMPLEMENTED: decided 2026-10-20*

### 13. Nix

- **FR-13.1** Hetzner cloud realm (`cloud/`, `scripts/cloud/`, `nix/disko/`,
  `nix/hosts/forge-cloud*.nix`).
  *TO BE REMOVED: decided 2026-10-20; never verified live*
- **FR-13.2** NixOS all-in-one test VM (`nix/hosts/forge-vm.nix`,
  `docs/nixos-vm.md`, `scripts/setup_wizard.py`, `scripts/client_fetch.py`
  and their tests) and the NixOS workstation module (`nix/modules/`).
  *TO BE REMOVED: decided 2026-10-20. The user's NixOS machine sets up its own
  rootless Docker (`docs/linux-headless.md` in PR #14)*
- **FR-13.3** The flake MUST provide a dev shell (`nix develop`) and the
  `forge` package, and MUST build with lupa.
  *PARTIAL: `flake.nix`; lupa was added to the flake without a Nix build
  (`docs/agent-playbook.md`)*

### 14. Spec-driven addons (Track B)

- **FR-14.1** `forge new` MUST also create `<root>/<Name>-requirements.md`
  beside the acceptance plan (never inside the addon folder, so it is never
  deployed), with `FR-`, `NFR-` and `OQ-` sections and a status for each
  requirement.
  *NOT IMPLEMENTED: `docs/spec-driven.md` (Track B); location decided
  2026-10-20*
- **FR-14.2** Plan checks MUST be able to name the addon requirements they
  cover (`"covers": ["FR-1.2"]`), and spec tests MUST be able to name them in
  their titles.
  *NOT IMPLEMENTED: `docs/spec-driven.md`*
- **FR-14.3** `forge check` MUST fail when an addon requirement has no offline
  spec, or when a spec or plan names an ID that does not exist. It MUST list
  open `OQ-` items. A plan check per requirement is optional (some behaviour,
  such as ties, cannot be forced live). Addons without a requirements file
  are not checked; `forge new` creates one, so new addons are.
  *NOT IMPLEMENTED: decided 2026-10-20; exemption decided 2026-10-21 (second question pass)*
- **FR-14.4** A run-plan result MUST list pass or fail for each covered addon
  requirement.
  *NOT IMPLEMENTED: `docs/spec-driven.md`*
- **FR-14.5** RaidLedger and RaidWishlist MUST be the first addons with
  requirements files, holding every loot rule the user chose, each covered by
  an offline spec.
  *NOT IMPLEMENTED: decided 2026-10-20*
- **FR-14.6** An addon's requirements file MUST list each addon message kind
  and import format the addon accepts. `forge check` MUST fail when one of
  them lacks an offline spec for a malformed input or one for an unauthorized
  sender. Message kinds use their own `MSG-` IDs (`MSG-1`, `MSG-2`, ...), and
  spec titles name them (`MSG-3 malformed ...`, `MSG-3 unauthorized ...`).
  *NOT IMPLEMENTED: decided 2026-10-21 (SECURITY.md SC-019, OD-007)*

### 15. Release gate

- **FR-15.1** `forge release <Addon>` MUST copy the addon into the
  `wow-addons` checkout named by `[release] addons_repo` in
  `forge.local.toml`, and commit it there, and MUST NOT push. The commit goes
  on a new branch `release/<Addon>-<version>` cut from `origin/main`, in a
  separate worktree, so the user's checkout is left as it is. The copy is the
  `.toc`, the files it lists, the addon's `README.md` and its `LICENSE`
  (license text must travel with a GPL addon; added 2026-10-26); files of
  the old version that the new `.toc` no longer lists are removed.
  *IMPLEMENTED (live: RaidWishlist 2.1.0, 2026-10-24, five plans passed, robinschweitz/wow-addons#7 and robinschweitz/raid-website#153): `release.py::release`; `test_release.py::test_every_plan_passes_then_both_repositories_get_a_branch_and_a_commit`*
- **FR-15.2** `forge release` MUST run every acceptance plan of the addon
  itself, as live sessions on exactly the files being released (it needs
  `--approve-fixtures`), and MUST refuse unless all pass. It MUST NOT rely on
  earlier result files, and MUST name the plans that failed. The plans of an
  addon are the plan files beside its folder whose `addon` is that addon.
  *IMPLEMENTED (live: RaidWishlist 2.1.0, 2026-10-24, five plans passed, robinschweitz/wow-addons#7 and robinschweitz/raid-website#153): `test_release.py::test_a_failing_plan_stops_the_release_and_is_named`, `::test_an_infrastructure_error_counts_as_not_passed`, `::test_old_result_files_are_never_a_pass`, `::test_plans_of_an_addon_are_the_plan_files_beside_it_that_name_it`*
- **FR-15.3** A released copy MUST NOT contain `tests/`, `.forge-runs/` or the
  test bridge.
  *IMPLEMENTED (live: RaidWishlist 2.1.0, 2026-10-24, five plans passed, robinschweitz/wow-addons#7 and robinschweitz/raid-website#153): `release.py::release_files`; `test_release.py::test_released_files_are_the_toc_its_files_and_the_readme`*
- **FR-15.4** `forge release` MUST refuse when any file of the addon changed
  between the first live run and the copy (content hash), and when the
  addon's `.toc` version is already the one on the `wow-addons` main branch.
  *IMPLEMENTED (live: RaidWishlist 2.1.0, 2026-10-24, five plans passed, robinschweitz/wow-addons#7 and robinschweitz/raid-website#153): `test_release.py::test_a_file_changed_during_the_runs_stops_the_release`, `::test_an_already_released_version_is_refused_before_any_run`*
- **FR-15.5** When `[release] website_repo` names a `raid-website` checkout,
  `forge release` MUST, after the `wow-addons` commit, run the website's own
  `go run ./cmd/sync-addons <release worktree>` on a new branch
  `addons/<Addon>-<version>` cut from `origin/main` (separate worktree),
  commit the synced bundle, and MUST NOT push. It MUST list the website files
  outside the bundle that name the addon (pages, changelog), which still need
  a human or agent update in the same change.
  *IMPLEMENTED (live: RaidWishlist 2.1.0, 2026-10-24, five plans passed, robinschweitz/wow-addons#7 and robinschweitz/raid-website#153): `test_release.py::test_every_plan_passes_then_both_repositories_get_a_branch_and_a_commit`, `::test_the_website_sync_may_change_only_the_released_addon` (another addon's bundle may not change; no half release); the real `cmd/sync-addons` ran against raid-website `origin/main` on 2026-10-24*
- **FR-15.6** Without `--approve-fixtures`, `forge release` MUST only preview:
  the plans it would run, the version, the files it would copy and the
  branches it would create. It MUST NOT start a client or write to either
  repository.
  *IMPLEMENTED (live: RaidWishlist 2.1.0, 2026-10-24, five plans passed, robinschweitz/wow-addons#7 and robinschweitz/raid-website#153): `test_release.py::test_preview_changes_nothing_and_starts_no_client`, `::test_cli_previews_a_release`*

## Non-Functional Requirements

- **NFR-1.1** Addons MUST target WoW 3.3.5a build 12340: Lua 5.1 and
  `## Interface: 30300`. *IMPLEMENTED: FR-2.1, FR-2.3*
- **NFR-1.2** Static checks and offline specs MUST run on any OS with
  Python >= 3.11 and no system Lua (Lua 5.1 is embedded through lupa).
  *IMPLEMENTED: `pyproject.toml`; `.github/workflows/python.yml` (Ubuntu and
  Windows)*
- **NFR-1.3** Live acceptance MUST run on native Windows 10/11 with the
  WoWControlSDK, and on Linux with a headless Wine client.
  *PARTIAL: FR-7.5, FR-11.12*
- **NFR-1.4** An offline run that exceeds its instruction budget or memory
  cap (limits: SECURITY.md SC-008) MUST fail instead of hanging. *IMPLEMENTED: `test_offline.py::test_sandbox_blocks_host_access_and_infinite_loops`*
- **NFR-1.5** Every unclear live outcome MUST fail closed as `failed` or
  `infrastructure_error`, never `passed`. *IMPLEMENTED: FR-6.5, FR-6.6*
- **NFR-1.6** A session MUST NOT use the human's desktop for more than 10
  minutes. Steps MAY wait at most 180 s in total.
  *PARTIAL: FR-5.3; FR-7.7 is NOT IMPLEMENTED*
- **NFR-1.7** No speed target. The README's "milliseconds" and "sub-second"
  claims MUST be removed.
  *IMPLEMENTED: decided 2026-10-20; claims removed from `README.md` in
  `10e85c3`*
- **NFR-1.8** The full test suite MUST pass on every commit to `main`.
  *IMPLEMENTED: `tests/`; user's git habit (verified in a clean worktree)*
- **NFR-1.9** Forge's checks and specs MUST keep addons working in German
  (deDE) and English (enUS) clients (FR-4.12).
  *PARTIAL: decided 2026-10-20. deDE is verified live on Windows, enUS live on
  Linux (PR #14); FR-4.12 is NOT IMPLEMENTED*
- **NFR-1.10** Each addon MAY choose its own look. Forge enforces only
  readability: no overlapping or overflowing UI, full 25-raider data, and long
  German names that fit.
  *PARTIAL: decided 2026-10-20; FR-4.7, FR-4.8, FR-2.11. Rules: `DESIGN.md`
  (Do's and Don'ts)*
- **NFR-1.11** Setup MUST work for a few friends on their own PCs, not only
  the owner's machines: no hard-coded paths, and guides that start from a
  fresh checkout.
  *PARTIAL: decided 2026-10-20. `docs/agent-playbook.md` names the owner's
  test-client path (`F:\Wow\wow_second`)*
- **NFR-1.12** The local realm MUST be built from pinned AzerothCore image
  versions and a pinned mod-ale build, so every user gets the same server.
  Updating a pin MUST be an explicit change.
  *NOT IMPLEMENTED: decided 2026-10-21 (ARCHITECTURE.md AQ-2). Setup uses
  mutable upstream tags today*

## Open Questions

None. The first question pass (2026-10-20) answered OQ-1 to OQ-11:

- **OQ-1** Answered: statuses backed by recorded run IDs win.
  `docs/qa-workflow.md` is current; the README was fixed in step A7.
- **OQ-2** Answered: remove `agent capabilities` (FR-10.10).
- **OQ-3** Answered: keep Linux, now headless (FR-11.9 to FR-11.12, PR #14).
- **OQ-4** Answered: remove the cloud realm, the VM and the NixOS module; keep
  the dev shell and the package (FR-13.1 to FR-13.3, FR-11.7).
- **OQ-5** Answered: `<Name>-requirements.md` beside the plan (FR-14.1).
- **OQ-6** Answered: no speed target (NFR-1.7).
- **OQ-7** Answered: 10 minutes (FR-7.7, NFR-1.6).
- **OQ-8** Answered: fail when a requirement has no offline spec (FR-14.3).
- **OQ-9** Answered: a general boss fight with phases first; quests deferred
  (FR-10.8, FR-10.12).
- **OQ-10** Answered: add `forge_session`, and let sessions close the test
  client (FR-12.5, FR-7.6).
- **OQ-11** Answered: yes (FR-10.11).
