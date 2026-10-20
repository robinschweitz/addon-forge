# Addon Forge Threat Model

This file owns the threats to Addon Forge and to addons built with it, their
evidence, and the gaps. Controls are in [SECURITY.md](SECURITY.md) (`SC-`,
`OD-`), trust boundaries and components in [ARCHITECTURE.md](ARCHITECTURE.md)
(`TB-`), behaviour in [REQUIREMENTS.md](REQUIREMENTS.md).

## Method and scope

- Method: STRIDE (Spoofing, Tampering, Repudiation, Information disclosure,
  Denial of service, Elevation of privilege) for each trust boundary TB-1 to
  TB-8, plus addons at runtime in a raid and the release path. Step A8 of
  [docs/spec-driven.md](docs/spec-driven.md); the Manicode threat-modeling
  pipeline was not available.
- Evidence: the code on `main` at `10e85c3`, its tests, PR #14 and the docs.
  Missing information is recorded as an evidence gap, not as a vulnerability.
- No risk scores: the specs give no scale. Status per threat:
  `MITIGATED` (control and test exist), `PARTIAL`, `OPEN` (needs work or a
  decision), `ACCEPTED` (risk accepted by the user).
- Assets: the user's computer and files; realm and vault credentials; the
  user's other WoW installation (Rising Gods); the integrity of test verdicts;
  raiders' games running released addons; the raid's shared loot data.
- Attackers considered: a mistaken or misled AI agent; AI-written addon code
  that is buggy or games its tests; a compromised third-party dependency (SDK,
  images); a prankster in the raid; another program on the user's machine.
  Out of scope: an attacker who already controls the user's account.

## Threats

### TB-1 Agent -> Forge

**T-001 - Agent approves its own live run** (Elevation of privilege)
- Threat: the approval flags are plain CLI options. An agent with shell access
  can run `forge ... --approve-fixtures` itself; only MCP enforces that the
  human set the flag.
- Evidence: `cli.py` (flags parsed from argv); `mcp_server.forge_run_plan`.
  The playbook's standing permission makes this intended for the owner's
  agents, with an announcement before each run.
- Controls: SC-001 (MCP only); announcement before each run; planned run
  log (FR-6.12, OD-008).
- Status: PARTIAL. Accepted as the standing-permission model; the log makes
  every approved run visible afterwards.

**T-002 - Path or plan injection** (Tampering, Elevation of privilege)
- Threat: an agent passes a plan or addon path outside `projects/`, or plan
  values that become Lua, shell or SQL.
- Evidence: `mcp_server.Forge._inside`; `scenario_plan.validate_plan`;
  `plan_steps._code`.
- Controls: SC-002, SC-003, SC-004.
- Status: MITIGATED.

**T-003 - Resource exhaustion through plans** (Denial of service)
- Threat: long waits, many steps or a hung client keep the user's desktop
  busy.
- Evidence: FR-5.1, FR-5.3 limits; no total session limit yet.
- Controls: SC-003; planned SC-021 (10-minute session, FR-7.7).
- Status: PARTIAL.

### TB-2 Addon and spec code -> host

**T-004 - Precompiled Lua escapes the offline sandbox** (Elevation of privilege)
- Threat: an addon or spec file that holds precompiled Lua 5.1 bytecode
  instead of source. Lua 5.1 does not verify bytecode safely, so a crafted
  chunk can break out of the sandbox and run code with the user's rights.
- Evidence: checked on 2026-10-21 with a harmless `string.dump` chunk as
  `Core.lua`: `forge check` passed and `forge spec` loaded and ran it. The
  harness blocks binary chunks only in the addon-visible `loadstring`
  (`headless/wow.lua`), not in its own file and spec loaders;
  `lua51.compile_chunk` accepts them too.
- Controls: none for files.
- Status: OPEN. Fix: SC-025, FR-2.9, FR-4.11.

**T-005 - Sandbox library access** (Elevation of privilege)
- Threat: addon code reaches `os`, `io`, `package`, `debug` or Python.
- Evidence: `headless/wow.lua` removes them before addon code runs; lupa
  runtime without eval and builtins.
- Controls: SC-008.
- Status: MITIGATED (source code only; see T-004).

**T-006 - Runaway addon code** (Denial of service)
- Threat: endless loops or memory growth in addon or spec code.
- Controls: SC-008 (budget, 256 MB cap); NFR-1.4.
- Status: MITIGATED.

### TB-3 Forge -> game client

**T-007 - Acting on the wrong WoW** (Tampering, Information disclosure)
- Threat: Forge deploys to, types into or reads credentials of the user's
  real WoW (Rising Gods) or another window.
- Controls: SC-006 (marker, executable path), SC-007 (minimal typing),
  SC-005 (PID-verified pipe); Linux uses a private Xvfb display.
- Status: MITIGATED.

**T-008 - Input lands while the user works** (Tampering)
- Threat: a session sends keys while the user uses the desktop.
- Controls: announcement before each run (`AGENTS.md`); planned 10-minute
  limit (SC-021); Linux runs on a hidden display.
- Status: PARTIAL.

### TB-4 External SDK -> Forge

**T-009 - Compromised SDK source or build** (Tampering, Elevation of privilege)
- Threat: malicious upstream code runs inside the test client and on the
  user's machine.
- Controls: SC-017 (pinned commit, reviewed patch, approved build, separate
  workspace).
- Status: PARTIAL (review is manual; residual risk of third-party native code).

**T-010 - Other local programs use the SDK pipe** (Spoofing, Tampering)
- Controls: SC-005.
- Status: ACCEPTED (OD-001).

### TB-5 Client report -> Forge

**T-011 - Report parser abuse** (Tampering, Denial of service)
- Threat: a crafted SavedVariables or JSON report runs code or exhausts
  memory in Forge.
- Controls: SC-009 (no execution; nesting and size limits).
- Status: MITIGATED.

**T-012 - Stale or mismatched report counted as a pass** (Tampering)
- Controls: SC-009 (run ID, bridge v3); FR-6.4 (stale client).
- Status: MITIGATED.

**T-013 - Addon under test fakes its verdict** (Tampering, Repudiation)
- Threat: the bridge runs in the same Lua state as the addon. An addon can
  overwrite `ForgeTestBridge` functions, register fake frames, replace the
  error handler, or raise errors whose text names another addon's file so
  they count as foreign. A test pass then says nothing.
- Evidence: `wow/ForgeTestBridge/Core.lua` (global table);
  `scenario_plan.split_errors` (classifies by message text).
- Controls: agents must not fake passes (`AGENTS.md`); planned SC-026
  (`forge check` rejects bridge and error-handler tampering, FR-2.10; errors
  attributed by source location, FR-6.13).
- Status: OPEN until SC-026 is built. Residual: an addon can still draw
  misleading UI; screenshots stay supporting evidence.

### TB-6 Forge -> realm

**T-014 - Realm reachable from the network** (Information disclosure, Elevation of privilege)
- Controls: SC-012 (loopback only, private `.env`); planned SC-024 (no SOAP).
- Status: MITIGATED (SOAP port closure planned).

**T-015 - Realm data destroyed** (Tampering, Denial of service)
- Controls: SC-013.
- Status: MITIGATED.

**T-016 - Fixture leftovers change the world** (Tampering)
- Evidence: a leftover fixture creature killed the Nordhaintal guards and the
  test characters (`docs/agent-playbook.md`, 2026-10-18 and 2026-10-20).
- Controls: FR-10.2 (cleanup, revive, wait until the corpse is gone).
- Status: PARTIAL (a manual worldserver restart is still the last resort).

**T-017 - Fixture database access as root** (Elevation of privilege)
- Controls: SC-014.
- Status: ACCEPTED (OD-003).

**T-018 - Unreviewed server Lua** (Elevation of privilege, Tampering)
- Threat: mod-ale runs server Lua with full libraries inside the worldserver
  container and reloads changed scripts automatically. Any file placed in the
  realm's `lua_scripts` folder runs there.
- Evidence: agent memory of 2026-10-20 (mod-ale on the owner's realm; folder
  outside this repository). Plans cannot carry server Lua (SC-014).
- Controls: planned FR-10.13 (fixture scripts kept and reviewed in this
  repository, copied into the realm; OD-010).
- Status: OPEN until FR-10.13 is built. Residual: scratch scripts while a
  fixture is being written.

**T-019 - Pinned images replaced upstream** (Tampering)
- Controls: planned SC-023 (digest pins).
- Status: PARTIAL (not built).

### TB-7 Human approval

See T-001.

### TB-8 Other addons in the client

**T-020 - Foreign errors hide or blame** (Tampering)
- Threat: errors of other enabled addons fail the addon under test, or the
  addon's own errors are filed as foreign.
- Controls: FR-6.7 (path-based split; unattributed errors stay owned).
- Status: PARTIAL (deliberate misattribution is T-013).

### Addons at runtime (raid)

**T-021 - Forged addon messages** (Spoofing, Tampering)
- Threat: a raid member sends fake ledger, roll or editor messages, or
  malformed ones that break the addon.
- Controls: SC-019; planned FR-14.6 specs per message kind.
- Status: PARTIAL.

**T-022 - Escape codes in received text** (Tampering, Spoofing)
- Threat: received names or text carry `|T`, `|c` or `|H` codes that draw
  textures, fake links or recolour text.
- Controls: SC-019; DESIGN.md (Do's and Don'ts).
- Status: PARTIAL (coverage per addon not checked yet, FR-14.6).

### Release path

**T-023 - Untested or altered code reaches raiders** (Tampering)
- Threat: a release contains files that never passed live, or the test
  bridge.
- Controls: planned SC-020 (FR-15).
- Status: OPEN until built.

**T-024 - Forged pass records** (Repudiation, Tampering)
- Threat: the release gate reads recorded passing runs from `.forge-runs/`,
  plain files that any agent can write.
- Evidence: `.forge-runs/` is git-ignored and unprotected.
- Controls: FR-15.2 (release re-runs every plan live and ignores earlier
  result files; OD-011).
- Status: MITIGATED by design once FR-15 is built.

### Secrets

**T-025 - Credential leaks** (Information disclosure)
- Controls: SC-011 (vault only, never argv or logs); SC-018 (Git ignores).
- Status: MITIGATED; uploads to AI providers ACCEPTED as instruction only
  (OD-006).

## Gaps

- **Evidence gaps:** whether the 3.3.5a client itself refuses precompiled
  addon files (`UNKNOWN`; the fix does not depend on it); how the owner's
  `lua_scripts` folder is written and reviewed (T-018); whether the SDK
  works under Wine (FR-11.13) and with what pipe access.
- **Conflict found:** "an agent cannot grant itself approval"
  (REQUIREMENTS.md inputs, ARCHITECTURE.md TB-7, SC-001) is true only for MCP
  (T-001). The specs now say so.

## Coverage

| Boundary | S | T | R | I | D | E |
|---|---|---|---|---|---|---|
| TB-1 Agent -> Forge | T-001 | T-002 | - | - | T-003 | T-001, T-002 |
| TB-2 Addon code -> host | - | - | - | - | T-006 | T-004, T-005 |
| TB-3 Forge -> client | - | T-007, T-008 | - | T-007 | - | - |
| TB-4 SDK -> Forge | T-010 | T-009, T-010 | - | - | - | T-009 |
| TB-5 Report -> Forge | - | T-011, T-012, T-013 | T-013 | - | T-011 | - |
| TB-6 Forge -> realm | - | T-015, T-016, T-018, T-019 | - | T-014 | T-015 | T-014, T-017, T-018 |
| TB-7 Approval | T-001 | - | - | - | - | T-001 |
| TB-8 Other addons | - | T-020 | - | - | - | - |
| Raid runtime | T-021, T-022 | T-021, T-022 | - | - | - | - |
| Release | - | T-023, T-024 | T-024 | - | - | - |
| Secrets | - | - | - | T-025 | - | - |

Empty cells: no supported threat found in the evidence, not proof of safety.
