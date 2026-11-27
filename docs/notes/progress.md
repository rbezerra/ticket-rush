# Progress log

Newest entry first.

## 2026-11-26 — Phase 2 complete (Tasks 3 and 4 verified)

- **Agent:** Antigravity
- **Branch:** `feature/phase-2-ecto` (branched from `origin/main` after PR #1 merged)

**Done and verified**
- Completed full 5-stage design/readiness review on Phase 2 and updated `docs/2026-11-25-ticket-rush-design.md` and `docs/plans/2026-11-25-ticket-rush-implementation-plan.md` with *Active Schema Contracts (Phases 3–9)*.
- Task 3: added `migration_timestamps: [type: :utc_datetime]` to `api/config/config.exs`, created `api/priv/repo/migrations/20261126225500_create_events_seats_reservations.exs` (`events`, `seats`, `reservations` with UTC timestamps, `CHECK` constraints, per-user `[:user_id, :idempotency_key]` uniqueness, `one_active_reservation_per_seat`, and `reservations_held_expiry_idx`), wrote `docs/notes/phase2.md`, and verified `api/test/ticket_rush/schema_invariant_test.exs` (`9 tests, 0 failures`, `0.7s`).
- Task 4: created `TicketRush.Events.Event`, `TicketRush.Events.Seat`, `TicketRush.Reservations.Reservation` (with `Ecto.Enum` statuses, `:utc_datetime` timestamps, and `hold_changeset/2`), and `TicketRush.Fixtures`. Verified `mix compile --warnings-as-errors`, `api/test/ticket_rush/reservations/reservation_test.exs` (`6 tests, 0 failures`, `6.3s`), and the full test suite (`17 tests, 0 failures`, `4.1s`).

**Not done**
- Phase 3 (Strategy B — Postgres only) has not started.

**Exact next step**
1. Owner reviews and merges the Phase 2 PR into `main`.
2. Create `feature/phase-3-strategy-b` from `main` and start **Phase 3, Task 5** (`Reservations.Strategy` behaviour and Postgres implementation), following *Active Schema Contracts (Phases 3–9)* in the plan (`Ecto.Enum` atoms, integer `user_id`, per-user `{user_id, idempotency_key}` lookups, and atomic `confirm`/expiry SQL guards).

---

## 2026-11-26 — Phase 1 complete (Tasks 1 and 2 verified)

- **Agent:** Antigravity
- **Branch:** `feature/phase-1-skeleton` (branched from `origin/agent/claude`, which started at `plan-v1`)

**Done and verified**
- Harness updated per owner request (`d916612`): switched from per-agent branches to feature branches (`feature/phase-<N>-<short-name>`) with handoff via `docs/notes/progress.md`.
- Task 1, Step 5: `docker compose up -d db` and `docker compose ps db` verified `ticket-rush-db-1` (`postgres:17`) reaches `Up (healthy)`.
- Task 2, Step 1: generated Phoenix API skeleton in `api/` via Docker `elixir:1.18` + `phx_new 1.8.17` (`--no-html --no-assets --no-mailer --no-gettext --no-dashboard --install`). Removed nested `api/.git` initialized by `phx.new`.
- Task 2, Steps 2–4: updated `api/config/dev.exs` and `api/config/test.exs` to use `hostname: System.get_env("DATABASE_HOST", "localhost")`; ran `docker compose run --rm api mix ecto.create` (`The database for TicketRush.Repo has already been created`) and `docker compose run --rm -e MIX_ENV=test api mix test` (`2 tests, 0 failures`, `0.03s`).
- Task 2, Steps 5–6: recorded generated module names, dependency versions (`phoenix ~> 1.8.17`, `ecto_sql ~> 3.13`, `bandit ~> 1.5`), and supervision tree study notes in `docs/notes/phase1.md`. All plan assumptions hold.

**Not done**
- Phase 2 (Ecto schemas and migrations) has not started.

**Exact next step**
1. Owner reviews and approves Phase 1 (optionally merging `feature/phase-1-skeleton` into `main`).
2. Create `feature/phase-2-ecto` from `main` (or from `feature/phase-1-skeleton` if not yet merged) and start **Phase 2, Task 3** (migrations for `events`, `seats`, `reservations`, test-first with `api/test/ticket_rush/schema_invariant_test.exs`).

---

## 2026-11-25 — stopped at Phase 1, Task 1, Step 5 (blocked by environment)

- **Branch (historical):** `agent/claude` (from tag `plan-v1`).

**Done and checked**
- Task 1, Steps 1–4: created `docker-compose.yml` (services `db`, `api`, `bench`), `api/Dockerfile.dev`, `Makefile`, and appended build/dependency entries to `.gitignore`.
- `docker compose config -q` passes; `make -n up test` prints the expected commands.

**Not done / not verified**
- Task 1, Step 5 (`make up`, Postgres must report `healthy`) was **never run successfully**. The Docker daemon is a remote endpoint and the execution environment answered `403 Forbidden`:
  `unable to get image 'postgres:17': error during connect: Get "https://192.168.120.2:2376/v1.54/images/postgres:17/json": Forbidden`
- No Docker image was pulled and no container was started, so nothing in the Elixir/Phoenix/Postgres side has been executed yet. Treat all code in the plan as untested.
- The Task 1 commit therefore predates its own verification step. Do not consider Task 1 finished until Step 5 passes.

**How to resume (in an environment with Docker access)**
1. `git switch agent/claude` (or branch from it) and read `AGENTS.md`.
2. Task 1, Step 5: `make up`, then `docker compose ps db`. Expected: `db` is `healthy`. If it is, Task 1 is complete.
3. Continue with Task 2 (generate the Phoenix app). Do not skip Task 2, Step 5: record the names the generator really produced before writing tests, because the plan's snippets assume `TicketRush.DataCase`, `TicketRushWeb.ConnCase`, `use TicketRushWeb, :controller`/`:channel` and `~p` routes.

**Decisions made so far (not obvious from the code)**
- ~~One branch per agent (`agent/<name>`), all created from tag `plan-v1`.~~ Superseded 2026-11-25 by owner decision: branches are named per feature (`feature/phase-<N>-<name>`) and work is handed off between agents through this log. See "Branching and handoff" in `AGENTS.md`. `main` stays the shared baseline.
- No BFF/gateway; production hardening, a React/TypeScript web app and CI/CD to Fly.io were added to the plan (see design doc).
