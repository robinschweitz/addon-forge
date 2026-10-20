# Spec-driven development in Addon Forge

Adapted from Manicode's "Bootstrap an empty repo" (v5, 12 steps). That playbook
assumes an empty repository. Addon Forge already has code, tests and live-verified
behaviour, so the steps change in the places listed below. The work runs in two
tracks:

- **Track A**: specify the Forge tool itself (steps A1-A12).
- **Track B**: make every addon built with Forge spec-driven. Track B is the
  first feature built from the Track A specs.

## What changes for an existing repository

| PDF step | PDF assumption | Here |
|---|---|---|
| 01 Requirements | Project notes are the only source | Sources are the code, tests, `README.md`, `AGENTS.md` and `docs/`. Each requirement records **Status** (`IMPLEMENTED`, `PARTIAL`, `NOT IMPLEMENTED`) and **Evidence** (test or source path). A claim in docs without code or tests becomes an `OQ-`. |
| 02 Design + logo | Web/mobile UI | No logo. `DESIGN.md` holds the UI rules for addons built with Forge (3.3.5a widgets, fonts, deDE strings, the layout issues `forge.layoutIssues` detects). |
| 03 Architecture | Nothing exists | Replaces `docs/architecture.md`. Components are the ones in `src/`, `wow/`, `agent_scenarios/` and the realm. |
| 04 Security | Manicode secure-coding corpus | We don't have that corpus. Sources are the `AGENTS.md` capability boundaries and the real attack surface: MCP tools, the `--allow-fixtures` gate, the realm gateway, fixture SQL, test-client patching, `forge.local.toml` credentials, and what may be uploaded to an AI provider. |
| 05 Template | Web/mobile/API fields (ASVS, NIST, jurisdiction) | A shorter template. Fields that never apply to a local addon tool are removed instead of set to `N/A`. |
| 06 AGENTS.md | New file | The file already exists. Add `@` imports and keep only the rules the specs don't already cover. |
| 07 Reconcile | Five spec files | The spec files plus `docs/*.md`. Docs remain runbooks and reference specs by ID. |
| 08 Threat model | Manicode threat-modeling pipeline | We don't have that pipeline either. Instead, run a STRIDE pass per trust boundary from `ARCHITECTURE.md`. |
| 09, 11 Questions | — | No change: one question at a time; answers go into the owning file. |
| 10 Backlog | Every requirement becomes an issue | Only `PARTIAL` and `NOT IMPLEMENTED` requirements become leaf issues. `IMPLEMENTED` ones go into the epic's coverage matrix with their evidence. Needs `gh auth login` first. |
| 12 Implement | Generic tests | Gates are `pytest`, `forge check`, `forge spec` and, for live behaviour, `agent session` (the run rules in `docs/agent-playbook.md`). |

## Files and ownership

All spec files live in the repository root.

| File | Owns | IDs |
|---|---|---|
| `REQUIREMENTS.md` | What Forge must do | `FR-`, `NFR-`, `OQ-` |
| `DESIGN.md` | UI rules for addons built with Forge | `DQ-` |
| `ARCHITECTURE.md` | Components, boundaries, data flow, technology | `DR-`, `AQ-` |
| `SECURITY.md` | Safety and secure-coding rules, open security decisions | `SC-`, `OD-` |
| `THREAT_MODEL.md` | Threats, evidence, gaps | `T-` |
| `REQUIREMENT_TEMPLATE.md` | Shape of each leaf issue | — |
| `AGENTS.md` | Agent working rules, commands | — |

Markers: `UNKNOWN` (fact not given), `TO BE DECIDED` (decision not made),
`ASSUMPTION`, `PROPOSED`, `DEFERRED`, `BLOCKED`. IDs are never reused.

## Track A: specify Forge

1. **A1 Requirements.** Read the code, tests and docs, and write `REQUIREMENTS.md`
   (capability groups: scaffold, static check, offline specs, plan schema, live
   runner, bridge, realm fixtures, MCP, client setup). Only behaviour that code,
   tests or docs show becomes a requirement.
2. **A2 Design.** `DESIGN.md` from the emulator's layout checks, the reference
   addons (`examples/RaidLedger`, `examples/RaidWishlist`) and
   live-run lessons.
3. **A3 Architecture.** Turn `docs/architecture.md` into `ARCHITECTURE.md`, with
   a Mermaid trust-boundary diagram.
4. **A4 Security.** `SECURITY.md` with `SC-` rules. Each rule has Status, Rule,
   Enforcement, Evidence and Verification.
5. **A5 Template.** The shorter `REQUIREMENT_TEMPLATE.md`.
6. **A6 Agents.** `AGENTS.md` imports the four specs.
7. **A7 Reconcile.** Each fact lives in one file; the others reference it.
8. **A8 Threat model.** STRIDE per boundary into `THREAT_MODEL.md`. Supported
   findings go back into the specs.
9. **A9 Questions.** One question at a time until every open item is answered
   or `DEFERRED`.
10. **A10 Backlog.** One epic, `REQ-DECISION-` issues and leaf issues in
    `robinschweitz/addon-forge`. Every leaf follows the template.
11. **A11 Reconcile backlog.** The second question pass, over specs and issues.
12. **A12 Implement.** One branch and one PR per leaf, in dependency order.

## Track B: spec-driven addons (outline, specified in A1)

- `forge new` scaffolds `<Name>-requirements.md` beside the acceptance plan,
  outside the addon folder so it is never deployed (`FR-`, `NFR-`, `OQ-`).
- Plan checks carry `"covers": ["FR-1.2"]`; spec titles start with the ID
  (`test("FR-1.2 first roll counts", ...)`).
- `forge check` fails when a requirement has no offline spec or an ID doesn't
  exist, and lists open `OQ-` items. Plan checks per requirement are optional.
- The run-plan report lists pass or fail for each covered requirement.
- Pilot: RaidLedger and RaidWishlist. The loot rules agreed with the user are
  already requirements in all but format.
