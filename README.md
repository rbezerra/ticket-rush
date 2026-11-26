# ticket-rush

A numbered-seat ticketing platform built to stay correct under heavy contention, using Elixir/OTP, Phoenix, Ecto, and PostgreSQL.

Everything runs in **Docker** — you do **not** need Elixir, Erlang, Node, or PostgreSQL installed on the host.

## Prerequisites

- Docker and Docker Compose (`docker compose` v2+)
- `make` (optional; every `make` target has a direct `docker compose` equivalent below)

## Running locally (step by step)

All commands are run from the **repository root**.

### 1. Start PostgreSQL

```bash
docker compose up -d db
# or: make up
```

Verify the database is healthy:

```bash
docker compose ps db
```

### 2. Build the API container image

```bash
docker compose build api
```

### 3. Install dependencies and set up the database

```bash
docker compose run --rm api mix setup
```

`mix setup` runs `mix deps.get`, `mix ecto.create`, `mix ecto.migrate`, and `mix run priv/repo/seeds.exs` inside the `api` container (dependencies and build artifacts are cached in Docker volumes `api_deps` and `api_build`).

### 4. Start the Phoenix API server

```bash
docker compose up -d api
```

The API will run in the background at `http://localhost:4000` (inspect logs with `docker compose logs -f api`).

> Note: In Phase 1 (skeleton), no HTTP routes are defined yet, so requests to `http://localhost:4000/api` return `404` / `NoRouteError` until REST routes are added in Phase 5.

### 5. Run the test suite

```bash
docker compose run --rm -e MIX_ENV=test api mix test
# or: make test
# narrow to one file:
docker compose run --rm -e MIX_ENV=test api mix test test/ticket_rush_web/controllers/error_json_test.exs
```

## Useful commands

| Task | Docker Compose | Makefile |
| --- | --- | --- |
| Start Postgres | `docker compose up -d db` | `make up` |
| Stop all services | `docker compose down` | `make down` |
| Run API tests | `docker compose run --rm -e MIX_ENV=test api mix test` | `make test` |
| Interactive IEx shell | `docker compose run --rm api iex -S mix` | `make iex` |
| Open `psql` on dev DB | `docker compose exec db psql -U postgres ticket_rush_dev` | `make psql` |

## Documentation

- Architecture & design: [`docs/2026-11-25-ticket-rush-design.md`](docs/2026-11-25-ticket-rush-design.md)
- Implementation plan: [`docs/plans/2026-11-25-ticket-rush-implementation-plan.md`](docs/plans/2026-11-25-ticket-rush-implementation-plan.md)
- Working rules: [`AGENTS.md`](AGENTS.md)
- Progress & handoff log: [`docs/notes/progress.md`](docs/notes/progress.md)
