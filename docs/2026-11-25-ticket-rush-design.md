# ticket-rush — Design

A numbered-seat ticketing platform built for high contention (thousands of buyers fighting for the same show). The goal is twofold: showcase the target stack (Elixir/OTP, Phoenix, Ecto, Oban, Broadway, TypeScript, PostgreSQL) and serve as a guided Elixir refresher.

Implementation plan: [`docs/plans/2026-11-25-ticket-rush-implementation-plan.md`](plans/2026-11-25-ticket-rush-implementation-plan.md)

## Decisions

- Environment: Docker Compose for everything (Elixir, Node, Postgres). Nothing installed on the host.
- Use case: ticketing with high contention.
- No BFF/gateway: clients (the React SPA and the load tool) call the Phoenix API directly, which is closer to a real production deployment. TypeScript lives in `web/` (React) and `bench/` (load testing).
- Concurrency: two strategies (A: one GenServer per event; B: Postgres only) with a comparative benchmark.
- Production-ready scope (user decision): rate limiting and load shedding in the API, real authentication (bcrypt + signed tokens), health checks, telemetry and JSON logs, `mix release`, React/TypeScript front-end served by the same release, GitHub Actions CI and CD to Fly.io.
- Out of scope (YAGNI): real payments, password reset/email verification, Redis, multi-region.

## Architecture

```
Client ──► API (Elixir/Phoenix) ──► PostgreSQL
             Reservations context
              ├─ Strategy A: GenServer per event
              └─ Strategy B: Postgres locks
             Oban: hold expiration
             Broadway: batched audit pipeline
             Phoenix Channels: live seat map
```

Flow: hold a seat (5 min) → confirm (simulated payment). An expired hold is released by an Oban job.

## Data model

- `events` (id, name, starts_at, status)
- `seats` (id, event_id, section, row, number, price_cents); unique `(event_id, section, row, number)`; index on `event_id`
- `reservations` (id, seat_id, user_id, status `held|confirmed|expired|cancelled`, expires_at, idempotency_key, inserted_at)
  - no `event_id`: it is redundant with `seats.event_id`. Revisit only if `EXPLAIN ANALYZE` justifies denormalizing.
- `audit_events`: partitioned by month, fed by Broadway

Invariant enforced by the database itself:

```sql
CREATE UNIQUE INDEX one_active_reservation_per_seat
  ON reservations (seat_id) WHERE status IN ('held','confirmed');
```

## Strategies

Shared behaviour `Reservations.Strategy`: `hold/3`, `confirm/2`, `release/1`. Config selects the implementation; the same tests and benchmark run against both.

- **A (OTP):** `DynamicSupervisor` + `Registry` → one `EventArbiter` GenServer per event serializes reservations in memory; `init/1` rehydrates from the database after a crash. Risk: the mailbox of a very hot event.
- **B (Postgres):** a transaction using `INSERT ... ON CONFLICT DO NOTHING` backed by the partial index; `SELECT ... FOR UPDATE SKIP LOCKED` for "best available seat".

## API (`/api/v1`)

- `GET /events`, `GET /events/:id/seats?status=available` (cursor pagination)
- `POST /events/:id/reservations` (header `Idempotency-Key`), `POST /reservations/:id/confirm`, `DELETE /reservations/:id`
- Channel `event:<id>`: `seat_held`, `seat_released`, `seat_sold`
- Status codes: 201, 200 (idempotent replay), 401, 409 (taken), 410 (expired), 422, 429 (Plug rate limit, emitted by the API itself), 503 + `Retry-After` (arbiter overloaded or restarting)
- Auth: `POST /api/v1/users`, `POST /api/v1/sessions` → bearer token (`Phoenix.Token`); `/health` and `/ready` are public
- Note: Strategy A keeps state in memory per node, so production runs one machine, or Strategy B for horizontal scale

## Error handling

Elixir: "let it crash"; expected errors are `{:error, reason}` translated by a `FallbackController`. If the arbiter crashes: restart, 503 + `Retry-After`, the client retries safely thanks to the idempotency key. The Oban expiration job is idempotent (`held→expired` only if still `held`).

## Testing

ExUnit + Ecto Sandbox; StreamData (invariant: never two active reservations per seat, sold ≤ M) against both strategies; OTP tests (kill + rehydration); `Oban.Testing`; `Broadway.test_message/3`; benchmark with 5k–10k buyers (p50/p99, throughput, correctness).

## Layout

```
ticket-rush/
  docs/  docker-compose.yml  Dockerfile  fly.toml  api/  web/  bench/  scripts/  .github/workflows/
```

## Phases (each starts with an "Elixir Refresher" note)

1. Docker + Phoenix skeleton (Application, supervision, Mix)
2. Ecto + migrations
3. Strategy B
4. Strategy A
5. REST API + Channels
6. Oban + Broadway
7. Property tests + benchmark
8. Postgres optimization
9. Production hardening (rate limit, auth, health, telemetry, release)
10. Web front-end (React + TypeScript)
11. CI/CD and Fly.io deployment
