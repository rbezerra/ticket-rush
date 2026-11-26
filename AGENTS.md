# AGENTS.md

Working rules for any AI coding agent (or human) contributing to this repository.

## What this project is

`ticket-rush`: a numbered-seat ticketing platform built to stay correct under heavy contention. It also serves as a guided Elixir/OTP refresher, so explanations matter as much as code.

## Where things are

- Design and decisions: `docs/2026-11-25-ticket-rush-design.md`
- Implementation plan (source of truth for tasks, code and commands): `docs/plans/2026-11-25-ticket-rush-implementation-plan.md`
- Study notes written while implementing: `docs/notes/`

## Rules

1. **Follow the plan in order**, one task at a time. Each task is test-first: failing test, run, implement, run, commit.
2. **Stop and ask the owner** at every 🛑 checkpoint, whenever something is ambiguous, and before changing a decision recorded in the design. Do not guess.
3. **Everything runs in Docker** (`make` targets, `docker compose`). Do not install Elixir, Node or Postgres on the host.
4. **Language:** code, comments, docs and commit messages are in English.
5. **Commits:** small, one logical change each, Conventional Commits style (`feat:`, `fix:`, `docs:`, `test:`, `build:`, `ci:`, `perf:`). The repo-local git identity is already configured; never change global git config, never add `--author`.
6. **Decision history:** when you deviate from the plan or decide something non-obvious, record it in `docs/` (design doc, a note in `docs/notes/`, or an amendment at the end of the plan) in the same commit. The git log plus `docs/` is the project's memory.
7. **Network and permissions:** if a step fails because of blocked network or missing permissions, report exactly what failed. Do not work around it by editing sandbox, proxy or permission settings.
8. **Never commit** secrets, `.env` files, build output, or local agent state (`.claude/`, `.cursor/`, ...; already in `.gitignore`).

## Branching and handoff

Work is not tied to any agent. Any agent (or human) can continue another one's work.

- **Branches are named after features, not agents:** `feature/phase-<N>-<short-name>` (e.g. `feature/phase-1-skeleton`, `feature/phase-3-strategy-b`). Use one branch per phase, created from `main` once the previous phase has been merged (or from the previous feature branch if it hasn't been merged yet). Other prefixes are fine for side work: `fix/<topic>`, `docs/<topic>`, `ci/<topic>`.
- **`main`** is the shared baseline. When finishing a phase (or stopping at a reviewable milestone), push the feature branch to `origin` and open a Pull Request against `main` so the owner can review and comment before merging. Never merge into `main` yourself.
- **Handoff log:** `docs/notes/progress.md`, newest entry first. Before you stop (phase done, blocked, or out of budget), add an entry that says: date, `Agent:` (which tool/model), branch, what is done and verified (with real command output for verification steps), what is not done, and the exact next step. Commit it.
- **Resuming:** read the newest progress entry, check out the branch it names, and verify its claims (e.g. re-run the last test command) before you build on top of them.
- Agent names belong in progress entries and commit trailers if you want them, never in branch names.

## Useful commands (available after Task 1 of the plan)

```bash
make up      # start Postgres
make test    # run the API test suite in Docker (ARGS="path/to_test.exs" to narrow)
make iex     # IEx shell with the app loaded
make psql    # psql into the dev database
```
