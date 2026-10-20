# Requirement Template - Addon Forge

Use one copy of this template for each leaf implementation issue: one atomic
change to Forge, the test bridge, a realm fixture, or an addon built with
Forge.

Replace bracketed placeholders. Use `N/A` only when a field was considered and
does not apply. Use `TO BE DECIDED` when the answer is open; an open answer
blocks the issue until its `REQ-DECISION-` issue is closed.

Uppercase normative terms use BCP 14 semantics (RFC 2119, RFC 8174). Prefer
`MUST`, `MUST NOT`, `SHOULD`, `SHOULD NOT` and `MAY`. Split compound behaviour
into separate requirements.

## Metadata

- **ID**: [REQ-AREA-###, e.g. REQ-SESSION-010]
- **Title**: [Short requirement name]
- **Status**: [Draft | Ready | In Progress | Implemented | Verified Live | Deprecated]
- **Owner**: [Person responsible]
- **Last Updated**: [YYYY-MM-DD]
- **Priority**: [Critical | High | Medium | Low]
- **Requirement Type**: [Functional | Security | Reliability | Usability | Removal]
- **Source / Parent**: [Spec IDs (FR-, NFR-, SC-, T-, DQ-, AQ-, OD-), decision issue, epic or user decision with date]

## Requirement

- **Statement**: [One atomic, testable statement of what Forge or the addon MUST, MUST NOT, SHOULD, SHOULD NOT or MAY do.]
- **Rationale**: [Why: user decision, failed live run, threat, or spec gap. Do not add behaviour here.]
- **Assumptions**: [Assumptions this requirement depends on, or `None`.]
- **Out of Scope**: [Behaviour explicitly excluded, or `None`.]
- **Requirements Traceability**: [`REQUIREMENTS.md` IDs]
- **Design Traceability**: [`DESIGN.md` section or DQ ID, or `N/A`]
- **Architecture Traceability**: [`ARCHITECTURE.md` component, TB-, DR- or AQ- IDs]
- **Security Traceability**: [`SECURITY.md` SC- or OD- IDs, or `N/A`]
- **Threat Traceability**: [`THREAT_MODEL.md` T- IDs, or `N/A`]

## Scope

- **Applies To**: [CLI | MCP server | Offline layer (check, spec, API knowledge) | Plan schema | Orchestrator / session | Windows client driver | Linux client driver | Test bridge | Realm fixture | Realm setup | Release | Addon: <Name> | Docs | Multiple]
- **Components / Files**: [Components as named in `ARCHITECTURE.md`; main files]
- **Interfaces / Operations**: [CLI commands, MCP tools, plan keys, check or step types, spec API functions, slash commands, events, or addon messages]
- **Actors**: [Human operator, AI agent, raid member, raid lead, fixture bot, other addon]
- **Preconditions**: [State that MUST exist first, e.g. "test client closed", "realm running", "plan validates", or `None`]
- **Platforms**: [Any OS (offline) | Windows live | Linux live | Both live]
- **Locales**: [deDE and enUS | N/A]
- **Data Touched**: [Addon files, SavedVariables, plan, `.forge-runs/` evidence, client `Interface/AddOns`, realm database, vault credentials, or `None`]

## Security Context

- **Trust Boundary**: [TB- ID from `ARCHITECTURE.md`, or `N/A`]
- **Untrusted Inputs**: [Agent commands, plan JSON, addon or spec source, SDK replies, bridge reports, other players' messages, pasted imports, or `None`]
- **Approval Needed**: [None | --approve-fixtures | --allow-fixtures | --approve-local-setup | --approve-build]
- **Enforcement Point**: [Function or module that enforces the rule]
- **Abuse Case**: [What an agent, prankster, buggy addon or compromised dependency could attempt, or `N/A`]
- **Secrets Involved**: [Vault credentials, realm `.env`, or `None`. Secrets MUST NOT appear in argv, logs, files or Git.]

## Acceptance Criteria

Each acceptance criterion MUST:

- describe one observable pass/fail outcome
- be independently testable
- stay within the behaviour defined by the requirement
- name the preconditions, the action and the expected result
- avoid introducing new product behaviour

Use Given/When/Then.

1. **AC-01 - Expected behaviour**: Given [valid preconditions], when [actor or system action], then [observable result].
2. **AC-02 - Invalid input or refusal**: Given [invalid input, missing approval or wrong target], when [action], then [refusal with a clear message and no state change].
3. **AC-03 - Infrastructure failure**: Given [client, SDK, realm or fixture unavailable], when [action], then [`infrastructure_error`, never `passed`, with evidence kept].
4. **AC-04 - Additional criterion**: [Add only when needed. Remove when not applicable.]

## Failure Behavior

- **On Invalid Input**: [Rejection message and exit code; confirm no deploy, client input or realm change happens]
- **On Missing Approval**: [`plan_only` preview or `not_authorized`, or `N/A`]
- **On Client / Realm Failure**: [`infrastructure_error`, cleanup (fixtures, key bindings, peers), what stays running]
- **On Addon Failure**: [`failed` with the stage, the failing checks and captured Lua errors]
- **Evidence**: [Files written to `.forge-runs/` (result JSON, screenshots, fixture logs), or `None`]

## Test Strategy

- **Unit Tests (pytest)**: [Behaviour testable without a client: validation, decisions, error paths, mocked SDK/Win32/Go]
- **Offline Specs (`forge spec`)**: [Spec files and test names, for addon or bridge behaviour, or `N/A`]
- **Static Checks (`forge check`)**: [New diagnostics or `N/A`]
- **Live Run**: [Plan file and `agent session` run IDs that prove the behaviour, or `Not possible live: <reason>`, or `N/A`]
- **Security Tests**: [Negative tests for refusals, path confinement, unauthorized senders, malformed input, or `N/A`]
- **Acceptance-Criteria Traceability**: [Test, spec or plan check per `AC-` criterion]

## Dependencies

- **Upstream Requirements**: [Issue or requirement IDs that MUST be done first, or `None`]
- **Downstream Requirements**: [Issue or requirement IDs that depend on this one, or `None`]
- **External Dependencies**: [WoWControlSDK, AzerothCore image, AzerothGhost, mod-ale, Wine, Xvfb, or `None`]
- **Failure Impact**: [Effect when a dependency is missing, outdated or misbehaves]

## Implementation Notes

- **Constraints**: [WoW 3.3.5a (build 12340), Lua 5.1, Python >= 3.11, Go 1.26, platform limits]
- **Prohibited Approaches**: [e.g. free-form code or shell in plans, weakening checks, touching a non-test WoW, `docker compose down -v`]
- **Implementation Guidance**: [Non-normative hints that do not add or change behaviour]
- **AI Development Guidance**: [`AGENTS.md`, `docs/agent-playbook.md` sections, relevant SC- rules; spec first: reproduce as a failing test, then fix]
- **Recommended Implementation Model**: [Exact model ID with a one-line reason, or `NOT VERIFIED`]
- **Required Human Review**: [None | live run on the owner's desktop | realm change | release]
- **Open Decisions**: [Unresolved decisions that block approval or implementation, or `None`]
