# Progress log

Branch: `agent/claude` (from tag `plan-v1`). Newest entry first.

## 2026-11-25 — stopped at Phase 1, Task 1, Step 5 (blocked by environment)

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
