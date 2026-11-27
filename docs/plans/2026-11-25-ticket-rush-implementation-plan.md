# ticket-rush Implementation Plan

> **For the executor (human or AI agent):** implement this plan task by task, in order. Every task is test-first: write the failing test, run it, implement, run it again, then commit. Stop at every 🛑 checkpoint and ask the project owner before continuing. See [`AGENTS.md`](../../AGENTS.md) for the working rules (test-first, Docker-only execution, small Conventional Commits, feature branches + PRs, and recording deviations in `docs/notes/`).

**Goal:** Build a numbered-seat ticketing platform that prevents double-booking under high concurrency (5k–10k concurrent buyers), implemented with two interchangeable reservation strategies (OTP GenServer vs. Postgres locks) and compared with a benchmark. Doubles as a guided Elixir refresher.

**Architecture:** A Phoenix API owns the domain (`Reservations` context behind a `Strategy` behaviour). Strategy A uses one `EventArbiter` GenServer per event (Registry + DynamicSupervisor); Strategy B relies on Postgres transactions and a partial unique index. Oban expires holds, Broadway batches audit events, Channels push live seat updates. Clients talk to the Phoenix API directly (no BFF). The API is production-hardened (rate limiting, load shedding, token auth, health checks, telemetry, `mix release`). A React/TypeScript SPA in `web/` shows a live seat map and is served by the same release; `bench/` is a TypeScript load tool. GitHub Actions runs CI and deploys to Fly.io.

**Tech Stack:** Elixir 1.18 / OTP 28, Phoenix, Ecto, Oban, Broadway, StreamData, PostgreSQL 17, Bcrypt, Telemetry, Docker Compose, GitHub Actions, Fly.io. Node 22 + TypeScript + React + Vite + Zod + Vitest + fast-check for `web/` and `bench/`.

**Design:** [`docs/2026-11-25-ticket-rush-design.md`](../2026-11-25-ticket-rush-design.md)

## Conventions

- Everything runs in Docker (`make` targets below). Nothing is installed on the host. On hosts without `make` (e.g., Windows), run the equivalent `docker compose` commands directly (e.g., `docker compose run --rm -e MIX_ENV=test api mix test <path>`).
- Docs, code, comments and commit messages are in English.
- Commits use the repo-local personal identity (already configured). Never pass `--author` or change global config.
- Every phase starts with an **Elixir Refresher** box. Read it before coding.
- **STOP-and-ask checkpoints** (marked 🛑): pause and confirm with the project owner before continuing.
- Add a failure message to assertions whose invariant is not obvious from the expression alone.

## Known Environment Risks (read first)

1. The execution environment may restrict outbound network access (corporate proxy, sandboxed agent). Docker image pulls, `hex.pm`, `registry.npmjs.org`, `fly.io` and the GitHub API may be unreachable; `git push` over SSH may still work. 🛑 If a step fails with 403/Forbidden or a timeout, **stop and tell the owner which domain is blocked**; the owner decides whether to allow it. Never change network, sandbox or permission settings on your own.
2. Exact versions drift. Task 2 pins whatever resolves at execution time into `mix.lock` and `package-lock.json`; keep them committed.

---

## Phase 1 — Environment & Phoenix skeleton

> **Elixir Refresher: Application and supervision tree.**
> An OTP *application* is a component with a start callback (`Application.start/2`) that returns the root *supervisor*. A supervisor restarts children according to a strategy (`:one_for_one` = restart only the crashed child). Everything long-lived (Repo, PubSub, Endpoint, Oban) is a child in `lib/ticket_rush/application.ex`. "Let it crash" works because supervisors make crashing cheap.

### Task 1: Docker Compose and Makefile

**Files:**
- Create: `docker-compose.yml`, `api/Dockerfile.dev`, `Makefile`
- Modify: `.gitignore` (already exists with the agent-local folders; append the entries below)

**Step 1: Create `docker-compose.yml`**

```yaml
services:
  db:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports: ["5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 3s
      retries: 20

  api:
    build: { context: ./api, dockerfile: Dockerfile.dev }
    working_dir: /app
    volumes: ["./api:/app", "api_build:/app/_build", "api_deps:/app/deps"]
    environment:
      DATABASE_HOST: db
      MIX_ENV: dev
    depends_on: { db: { condition: service_healthy } }
    ports: ["4000:4000"]
    command: mix phx.server

  bench:
    image: node:22
    working_dir: /bench
    volumes: ["./bench:/bench", "bench_modules:/bench/node_modules"]
    environment: { API_URL: "http://api:4000" }
    profiles: ["bench"]

volumes: { pgdata: {}, api_build: {}, api_deps: {}, bench_modules: {} }
```

**Step 2: Create `api/Dockerfile.dev`**

```dockerfile
FROM elixir:1.18
RUN apt-get update && apt-get install -y inotify-tools build-essential && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
WORKDIR /app
```

**Step 3: Create `Makefile`**

```makefile
.PHONY: up down test iex psql
up:    ; docker compose up -d db
down:  ; docker compose down
test:  ; docker compose run --rm -e MIX_ENV=test api mix test $(ARGS)
iex:   ; docker compose run --rm api iex -S mix
psql:  ; docker compose exec db psql -U postgres ticket_rush_dev
```

**Step 4: `.gitignore`**

```
_build/
deps/
node_modules/
dist/
*.beam
.env
```

**Step 5: Verify the database comes up**

Run: `make up && docker compose ps db`
Expected: `db` shows `healthy`.

**Step 6: Commit**

```bash
git add docker-compose.yml api/Dockerfile.dev Makefile .gitignore
git commit -m "chore: add docker compose environment"
```

### Task 2: Generate the Phoenix app

**Files:**
- Create: `api/` (generated)

**Step 1: Generate (API-only, no HTML/assets/mailer)**

Run:
```bash
mkdir -p api && docker run --rm -v "$PWD/api":/app -w /app elixir:1.18 sh -c \
 "mix local.hex --force && mix archive.install hex phx_new --force && \
  mix phx.new . --app ticket_rush --module TicketRush --no-html --no-assets --no-mailer --no-gettext --no-dashboard --install"
```
Expected: `We are almost there!` message. 🛑 If hex.pm is blocked, stop and ask the user.

**Step 2: Point the Repo at the compose database**

Modify `api/config/dev.exs` and `api/config/test.exs`: set `hostname: System.get_env("DATABASE_HOST", "localhost")` in the `TicketRush.Repo` config.

**Step 3: Create and migrate**

Run: `docker compose run --rm api mix ecto.create`
Expected: `The database for TicketRush.Repo has been created`.

**Step 4: Smoke test**

Run: `make test`
Expected: `0 failures`.

**Step 5: Record the generated names (de-risks every later test)**

This plan was written without being able to run the generator, so module and helper names below are the *expected* ones. Before writing any test, run and note the real ones:

```bash
cd api && grep -n "defmodule" test/support/*.ex lib/ticket_rush_web.ex | head -20
grep -n "use TicketRushWeb" lib/ticket_rush_web/*.ex | head; grep -n "verified_routes\|~p" lib/ticket_rush_web.ex | head -3
grep -n "{:phoenix\|{:ecto_sql\|{:plug_cowboy\|{:bandit" mix.exs
```
Write the results in `docs/notes/phase1.md` under "Generated names" and compare with these assumptions: `TicketRush.DataCase` and `TicketRushWeb.ConnCase` exist with `errors_on/1`; `use TicketRushWeb, :controller` / `:channel` exist; `~p` verified routes are available; the web server is Bandit or Cowboy. 🛑 If any assumption is wrong, fix the affected snippets in this plan (search for the old name) and tell the user before continuing.

**Step 6: Read the supervision tree (study step)**

Open `api/lib/ticket_rush/application.ex`. Identify each child and write one line each in `docs/notes/phase1.md` answering: what does `Repo` restart on crash? Why is `Endpoint` last?

**Step 7: Commit**

```bash
git add -A && git commit -m "feat: generate phoenix api skeleton"
```

---

## Phase 2 — Ecto schemas and migrations

> **Elixir Refresher: Ecto.**
> `Repo` is the sole interface to the database. A *schema* maps a table to a struct. A *changeset* validates and casts input and declares constraint names (`unique_constraint`, `foreign_key_constraint`) so that database errors become `{:error, changeset}` instead of exceptions. Pattern matching on `{:ok, _}` / `{:error, _}` replaces exceptions for expected failures.

### Task 3: Migrations (events, seats, reservations)

**Files:**
- Modify: `api/config/config.exs` (add `config :ticket_rush, TicketRush.Repo, migration_timestamps: [type: :utc_datetime]`)
- Create: `api/priv/repo/migrations/*_create_events_seats_reservations.exs` (generate inside Docker via `docker compose run --rm api mix ecto.gen.migration create_events_seats_reservations`)
- Create: `docs/notes/phase2.md`
- Test: `api/test/ticket_rush/schema_invariant_test.exs`

**Step 1: Write the failing invariant test**

Create `api/test/ticket_rush/schema_invariant_test.exs`:

```elixir
defmodule TicketRush.SchemaInvariantTest do
  use TicketRush.DataCase, async: true

  setup do
    {:ok, %{rows: [[event_id]]}} =
      Repo.query("INSERT INTO events (name, starts_at, status, inserted_at, updated_at) VALUES ('E', now(), 'on_sale', now(), now()) RETURNING id")
    {:ok, %{rows: [[seat_id]]}} =
      Repo.query("INSERT INTO seats (event_id, section, row, number, price_cents, inserted_at, updated_at) VALUES ($1,'A','1',1,1000, now(), now()) RETURNING id", [event_id])
    %{event_id: event_id, seat_id: seat_id}
  end

  defp insert_reservation(seat_id, status, key, user_id) do
    Repo.query("INSERT INTO reservations (seat_id, user_id, status, expires_at, idempotency_key, inserted_at, updated_at) VALUES ($1,$2,$3, now() + interval '5 min', $4, now(), now())", [seat_id, user_id, status, key])
  end

  test "database rejects a second held reservation for the same seat", %{seat_id: seat_id} do
    assert {:ok, _} = insert_reservation(seat_id, "held", "k1", 1)
    assert {:error, %Postgrex.Error{postgres: %{constraint: "one_active_reservation_per_seat"}}} =
             insert_reservation(seat_id, "held", "k2", 2)
  end

  test "database rejects a new hold on an already confirmed seat", %{seat_id: seat_id} do
    assert {:ok, _} = insert_reservation(seat_id, "confirmed", "k1", 1)
    assert {:error, %Postgrex.Error{postgres: %{constraint: "one_active_reservation_per_seat"}}} =
             insert_reservation(seat_id, "held", "k2", 2)
  end

  test "an expired reservation does not block a new hold", %{seat_id: seat_id} do
    assert {:ok, _} = insert_reservation(seat_id, "expired", "k1", 1)
    assert {:ok, _} = insert_reservation(seat_id, "held", "k2", 2), "expired rows must not occupy the seat"
  end

  test "a cancelled reservation does not block a new hold", %{seat_id: seat_id} do
    assert {:ok, _} = insert_reservation(seat_id, "cancelled", "k1", 1)
    assert {:ok, _} = insert_reservation(seat_id, "held", "k2", 2), "cancelled rows must not occupy the seat"
  end

  test "database rejects invalid reservation status values", %{seat_id: seat_id} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "reservations_status_check"}}} =
             insert_reservation(seat_id, "invalid", "k1", 1)
  end

  test "database rejects invalid event status values" do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "events_status_check"}}} =
             Repo.query("INSERT INTO events (name, starts_at, status, inserted_at, updated_at) VALUES ('Bad', now(), 'invalid', now(), now())")
  end

  test "database rejects negative seat prices", %{event_id: event_id} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "seats_price_non_negative"}}} =
             Repo.query("INSERT INTO seats (event_id, section, row, number, price_cents, inserted_at, updated_at) VALUES ($1,'A','1',2,-1, now(), now())", [event_id])
  end

  test "database rejects non-positive seat numbers", %{event_id: event_id} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "seats_number_positive"}}} =
             Repo.query("INSERT INTO seats (event_id, section, row, number, price_cents, inserted_at, updated_at) VALUES ($1,'A','1',0,1000, now(), now())", [event_id])
  end

  test "idempotency key is scoped per user_id", %{seat_id: seat_id} do
    assert {:ok, _} = insert_reservation(seat_id, "expired", "same-key", 1)
    assert {:ok, _} = insert_reservation(seat_id, "held", "same-key", 2),
           "different users must be able to use the same idempotency key"
    assert {:error, %Postgrex.Error{postgres: %{constraint: "reservations_user_idempotency_key_index"}}} =
             insert_reservation(seat_id, "expired", "same-key", 1)
  end
end
```

**Step 2: Run, expect failure**

Run: `make test ARGS=test/ticket_rush/schema_invariant_test.exs`
Expected: FAIL (`relation "events" does not exist`).

**Step 3: Configure UTC timestamps on `Repo` and write the migration**

1. In `api/config/config.exs`, add a new config block **above** `import_config "#{config_env()}.exs"` (e.g., right after `config :ticket_rush, ecto_repos: ...`):

```elixir
config :ticket_rush, TicketRush.Repo,
  migration_timestamps: [type: :utc_datetime]
```

2. Generate the migration file inside Docker (`docker compose run --rm api mix ecto.gen.migration create_events_seats_reservations`) and edit `api/priv/repo/migrations/*_create_events_seats_reservations.exs` (`timestamps(type: :utc_datetime)` is kept explicit in the migration for readability alongside the Repo default):

```elixir
defmodule TicketRush.Repo.Migrations.CreateEventsSeatsReservations do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :name, :string, null: false
      add :starts_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "on_sale"
      timestamps(type: :utc_datetime)
    end
    create constraint(:events, :events_status_check,
             check: "status IN ('draft', 'on_sale', 'closed')")

    create table(:seats) do
      add :event_id, references(:events, on_delete: :delete_all), null: false
      add :section, :string, null: false
      add :row, :string, null: false
      add :number, :integer, null: false
      add :price_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end
    create unique_index(:seats, [:event_id, :section, :row, :number])
    create constraint(:seats, :seats_price_non_negative, check: "price_cents >= 0")
    create constraint(:seats, :seats_number_positive, check: "number > 0")

    create table(:reservations) do
      add :seat_id, references(:seats, on_delete: :restrict), null: false
      add :user_id, :bigint, null: false
      add :status, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :idempotency_key, :string, null: false
      timestamps(type: :utc_datetime)
    end
    create constraint(:reservations, :reservations_status_check,
             check: "status IN ('held', 'confirmed', 'expired', 'cancelled')")
    create unique_index(:reservations, [:user_id, :idempotency_key],
             name: :reservations_user_idempotency_key_index)
    create unique_index(:reservations, [:seat_id],
             where: "status IN ('held','confirmed')",
             name: :one_active_reservation_per_seat)
    create index(:reservations, [:expires_at], where: "status = 'held'",
             name: :reservations_held_expiry_idx)
  end
end
```

**Step 4: Run, expect pass**

Run: `make test ARGS=test/ticket_rush/schema_invariant_test.exs` (the `mix test` alias in `api/mix.exs` runs `ecto.create --quiet` and `ecto.migrate --quiet` automatically).
Expected: `9 tests, 0 failures`.

**Step 5: Write study notes**

Create `docs/notes/phase2.md` covering:
- Why the `WHERE status = 'held'` predicate keeps `reservations_held_expiry_idx` small.
- Why `on_delete: :restrict` is used on `reservations.seat_id`, and why production soft-closes events (`status = :closed`) instead of hard-deleting them to avoid sequential FK scans without a non-partial `seat_id` index.
- Schema rationales and **Alternatives Considered & Trade-offs**:
  - Partial unique index on `reservations(seat_id)` vs. a lockable `status`/`current_reservation_id` column on `seats`.
  - `varchar + CHECK` + `Ecto.Enum` vs. native PostgreSQL `ENUM`.
  - `:utc_datetime` (1-second precision) vs. `:utc_datetime_usec`.
  - Relying on the leftmost prefix of `unique_index(:seats, [:event_id, :section, :row, :number])` instead of a separate `seats(event_id)` index.
  - Per-user `[:user_id, :idempotency_key]` uniqueness vs. global `[:idempotency_key]`.
- Scaling limits and downstream notes:
  - Mutable `status` in both partial indexes disables PostgreSQL HOT updates on `reservations`; schedule `fillfactor` and `autovacuum` tuning in Phase 8.
  - Cross-reference the normative forward contracts in `Active Schema Contracts (Phases 3–9)` below (atomic state-transition/expiry SQL guards and Phase 9 `user_id` FK rollout).

**Step 6: Commit**

```bash
git add -A && git commit -m "feat: add events, seats and reservations migrations"
```

### Task 4: Schemas, changesets, and test fixtures

**Files:**
- Create: `api/lib/ticket_rush/events/event.ex`, `api/lib/ticket_rush/events/seat.ex`, `api/lib/ticket_rush/reservations/reservation.ex`
- Create: `api/test/support/fixtures.ex`
- Test: `api/test/ticket_rush/reservations/reservation_test.exs`

**Step 1: Write the failing changeset test**

Create `api/test/ticket_rush/reservations/reservation_test.exs`:

```elixir
defmodule TicketRush.Reservations.ReservationTest do
  use TicketRush.DataCase, async: true
  alias TicketRush.{Fixtures, Reservations.Reservation}

  defp future_expiry do
    DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)
  end

  test "hold_changeset requires seat, user, expires_at and idempotency key" do
    cs = Reservation.hold_changeset(%Reservation{}, %{})
    refute cs.valid?, "empty attrs must be invalid"
    assert %{
             seat_id: ["can't be blank"],
             user_id: ["can't be blank"],
             idempotency_key: ["can't be blank"],
             expires_at: ["can't be blank"]
           } = errors_on(cs)
  end

  test "hold_changeset enforces :held status and rejects unknown or non-held statuses" do
    valid_cs =
      Reservation.hold_changeset(%Reservation{}, %{
        seat_id: 1,
        user_id: 1,
        idempotency_key: "k",
        expires_at: future_expiry()
      })

    assert valid_cs.valid?
    assert Ecto.Changeset.get_field(valid_cs, :status) == :held

    invalid_cs =
      Reservation.hold_changeset(%Reservation{}, %{
        seat_id: 1,
        user_id: 1,
        idempotency_key: "k",
        expires_at: future_expiry(),
        status: :bogus
      })

    refute invalid_cs.valid?, "unknown status values must be rejected"
    assert %{status: ["is invalid"]} = errors_on(invalid_cs)

    confirmed_cs =
      Reservation.hold_changeset(%Reservation{}, %{
        seat_id: 1,
        user_id: 1,
        idempotency_key: "k",
        expires_at: future_expiry(),
        status: :confirmed
      })

    refute confirmed_cs.valid?, "hold_changeset must only allow :held status"
    assert %{status: ["is invalid"]} = errors_on(confirmed_cs)
  end

  test "hold_changeset rejects idempotency_key longer than 255 characters" do
    cs =
      Reservation.hold_changeset(%Reservation{}, %{
        seat_id: 1,
        user_id: 1,
        idempotency_key: String.duplicate("a", 256),
        expires_at: future_expiry()
      })

    refute cs.valid?, "idempotency_key over 255 chars must fail validation instead of raising a Postgres truncation error"
    assert %{idempotency_key: ["should be at most 255 character(s)"]} = errors_on(cs)
  end

  test "hold_changeset maps nonexistent seat_id to a changeset error instead of raising" do
    cs =
      Reservation.hold_changeset(%Reservation{}, %{
        seat_id: -1,
        user_id: 1,
        idempotency_key: "k-missing-seat",
        expires_at: future_expiry()
      })

    assert {:error, failed_cs} = Repo.insert(cs)
    assert %{seat_id: ["does not exist"]} = errors_on(failed_cs)
  end

  test "hold_changeset maps duplicate active seat to \"taken\" changeset error" do
    seat = Fixtures.seat!()
    attrs = %{seat_id: seat.id, user_id: 1, idempotency_key: "k1", expires_at: future_expiry()}
    assert {:ok, _} = %Reservation{} |> Reservation.hold_changeset(attrs) |> Repo.insert()

    dup_attrs = %{seat_id: seat.id, user_id: 2, idempotency_key: "k2", expires_at: future_expiry()}
    assert {:error, failed_cs} = %Reservation{} |> Reservation.hold_changeset(dup_attrs) |> Repo.insert()
    assert %{seat_id: ["taken"]} = errors_on(failed_cs)
  end

  test "hold_changeset maps duplicate (user_id, idempotency_key) to a changeset error" do
    [seat1, seat2] = Fixtures.seats!(2)
    attrs1 = %{seat_id: seat1.id, user_id: 1, idempotency_key: "dup-key", expires_at: future_expiry()}
    assert {:ok, _} = %Reservation{} |> Reservation.hold_changeset(attrs1) |> Repo.insert()

    attrs2 = %{seat_id: seat2.id, user_id: 1, idempotency_key: "dup-key", expires_at: future_expiry()}
    assert {:error, failed_cs} = %Reservation{} |> Reservation.hold_changeset(attrs2) |> Repo.insert()
    assert %{idempotency_key: ["has already been taken"]} = errors_on(failed_cs)
  end
end
```

**Step 2: Run, expect failure**

Run: `make test ARGS=test/ticket_rush/reservations/reservation_test.exs`
Expected: FAIL (module missing).

**Step 3: Implement schemas and fixtures**

Create `api/lib/ticket_rush/reservations/reservation.ex`:

```elixir
defmodule TicketRush.Reservations.Reservation do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "reservations" do
    field :user_id, :integer
    field :status, Ecto.Enum, values: [:held, :confirmed, :expired, :cancelled], default: :held
    field :expires_at, :utc_datetime
    field :idempotency_key, :string
    belongs_to :seat, TicketRush.Events.Seat
    timestamps()
  end

  def hold_changeset(res, attrs) do
    res
    |> cast(attrs, [:seat_id, :user_id, :status, :idempotency_key, :expires_at])
    |> validate_required([:seat_id, :user_id, :status, :idempotency_key, :expires_at])
    |> validate_inclusion(:status, [:held])
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> foreign_key_constraint(:seat_id)
    |> unique_constraint(:seat_id, name: :one_active_reservation_per_seat, message: "taken")
    |> unique_constraint(:idempotency_key, name: :reservations_user_idempotency_key_index)
  end
end
```

Create `api/lib/ticket_rush/events/event.ex`:

```elixir
defmodule TicketRush.Events.Event do
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime]

  schema "events" do
    field :name, :string
    field :starts_at, :utc_datetime
    field :status, Ecto.Enum, values: [:draft, :on_sale, :closed], default: :on_sale
    has_many :seats, TicketRush.Events.Seat
    timestamps()
  end
end
```

Create `api/lib/ticket_rush/events/seat.ex`:

```elixir
defmodule TicketRush.Events.Seat do
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime]

  schema "seats" do
    field :section, :string
    field :row, :string
    field :number, :integer
    field :price_cents, :integer
    belongs_to :event, TicketRush.Events.Event
    timestamps()
  end
end
```

Create `api/test/support/fixtures.ex` (shared test fixtures for Phase 2 and later phases):

```elixir
defmodule TicketRush.Fixtures do
  alias TicketRush.{Repo, Events.Event, Events.Seat}

  def event!(attrs \\ %{}) do
    defaults = %{name: "Show", starts_at: ~U[2030-01-01 20:00:00Z]}
    attrs =
      case Map.get(attrs, :starts_at) do
        %DateTime{} = dt -> Map.put(attrs, :starts_at, DateTime.truncate(dt, :second))
        _ -> attrs
      end

    Repo.insert!(struct!(Event, Map.merge(defaults, attrs)))
  end

  @doc "Inserts `n` seats for one event and returns them."
  def seats!(n, event \\ nil) do
    event = event || event!()
    for i <- 1..n//1 do
      Repo.insert!(%Seat{event_id: event.id, section: "A", row: "1", number: i, price_cents: 1000})
    end
  end

  def seat!, do: hd(seats!(1))
end
```

**Step 4: Run, expect pass**

Run: `make test ARGS=test/ticket_rush/reservations/reservation_test.exs`
Expected: `6 tests, 0 failures`.

Then run the full test suite (`make test`) to confirm all Phase 1 and Phase 2 tests compile and pass together (`17 tests, 0 failures`).

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add ecto schemas and hold changeset"
```

### Active Schema Contracts (Phases 3–9)

These contracts are authoritative for Phases 3–9 where downstream snippets have not yet been updated:

1. **Enum statuses:** `Reservation.status` (`:held | :confirmed | :expired | :cancelled`) and `Event.status` (`:draft | :on_sale | :closed`) are `Ecto.Enum` atoms in Elixir/Ecto (serialized as strings in JSON).
2. **Integer `user_id`:** `reservations.user_id` is `:bigint` (`:integer` in Ecto, no FK until Phase 9 adds `users`). Use integer IDs (`1`, `2`) before Phase 9 auth; in Phase 9, clean/backfill synthetic rows, add the FK via `NOT VALID` + `VALIDATE CONSTRAINT`, and switch `Reservation` to `belongs_to :user` + `foreign_key_constraint(:user_id)`.
3. **Per-user idempotency & dual unique indexes:** Idempotency lookups must filter by both `user_id` and `idempotency_key` (in Postgres queries and `EventArbiter`'s in-memory map). Because `reservations` enforces two unique indexes (`reservations_user_idempotency_key_index` and `one_active_reservation_per_seat`), Strategy B must disambiguate replay vs. `:taken` without running queries inside an aborted transaction.
4. **Atomic state transitions & expiry:** `confirm/2` must update atomically with `WHERE id = $1 AND user_id = $2 AND status = 'held' AND expires_at > now()`, and Oban hold expiration must update with `WHERE status = 'held' AND expires_at <= now()`.
5. **UTC timestamps:** All schema and migration timestamps use `:utc_datetime`.

---

## Phase 3 — Strategy B (Postgres only)

> **Elixir Refresher: behaviours and `Repo.transaction`.**
> A `@behaviour` is a compile-time contract (`@callback`) — Elixir's interface. `Repo.transaction/1` rolls back when the function raises or returns `Repo.rollback/1`; `{:error, changeset}` from `Repo.insert` does *not* roll back by itself, you must handle it. `with` chains happy-path matches and falls through on the first mismatch.

### Task 5: Strategy behaviour and Postgres implementation

**Files:**
- Create: `api/lib/ticket_rush/reservations/strategy.ex`, `postgres.ex`, `api/lib/ticket_rush/reservations.ex`, `api/test/support/reservation_strategy_case.ex`
- Test: `api/test/ticket_rush/reservations/postgres_test.exs`

**Step 1: Shared test case so both strategies run the same tests**

```elixir
defmodule TicketRush.ReservationStrategyCase do
  @moduledoc "Shared contract tests. `use` it with `strategy: Module`."
  defmacro __using__(opts) do
    quote do
      use TicketRush.DataCase, async: false
      alias TicketRush.Fixtures
      @strategy unquote(opts[:strategy])

      setup do: %{seat: Fixtures.seat!()}

      test "hold succeeds on a free seat", %{seat: seat} do
        assert {:ok, res} = @strategy.hold(seat.id, "u1", idempotency_key: "k1")
        assert res.status == "held", "new reservation must be held"
      end

      test "second hold on the same seat is :taken", %{seat: seat} do
        {:ok, _} = @strategy.hold(seat.id, "u1", idempotency_key: "k1")
        assert {:error, :taken} = @strategy.hold(seat.id, "u2", idempotency_key: "k2")
      end

      test "same idempotency key returns the original reservation", %{seat: seat} do
        {:ok, a} = @strategy.hold(seat.id, "u1", idempotency_key: "k1")
        assert {:replayed, b} = @strategy.hold(seat.id, "u1", idempotency_key: "k1")
        assert a.id == b.id, "replay must not create a second reservation"
      end

      test "an expired hold frees the seat", %{seat: seat} do
        {:ok, _} = @strategy.hold(seat.id, "u1", idempotency_key: "k1", ttl_seconds: -1)
        assert {:ok, _} = @strategy.hold(seat.id, "u2", idempotency_key: "k2")
      end

      test "confirm moves held to confirmed; release frees the seat", %{seat: seat} do
        {:ok, r} = @strategy.hold(seat.id, "u1", idempotency_key: "k1")
        assert {:ok, %{status: "confirmed"}} = @strategy.confirm(r.id, "u1")
        {:ok, r2} = @strategy.hold(Fixtures.seat!().id, "u1", idempotency_key: "k3")
        assert {:ok, %{status: "cancelled"}} = @strategy.release(r2.id)
      end
    end
  end
end
```

`Fixtures` comes from Task 4. Note the contract below: `hold/3` returns `{:ok, res}` for a new reservation and `{:replayed, res}` for a repeated idempotency key (the controller maps these to 201 and 200). This shape is final; later tasks must not change it.

**Step 2: Behaviour and test file**

```elixir
defmodule TicketRush.Reservations.Strategy do
  alias TicketRush.Reservations.Reservation
  @type hold_opts :: [idempotency_key: String.t(), ttl_seconds: integer()]
  @callback hold(seat_id :: integer(), user_id :: String.t(), hold_opts()) ::
              {:ok, Reservation.t()} | {:replayed, Reservation.t()} | {:error, :taken | Ecto.Changeset.t()}
  @callback confirm(reservation_id :: integer(), user_id :: String.t()) ::
              {:ok, Reservation.t()} | {:error, :not_found | :expired | :not_held}
  @callback release(reservation_id :: integer()) :: {:ok, Reservation.t()} | {:error, :not_found}
end
```
(Add `@type t :: %__MODULE__{}` to `Reservation`.)

```elixir
defmodule TicketRush.Reservations.PostgresTest do
  use TicketRush.ReservationStrategyCase, strategy: TicketRush.Reservations.Postgres
end
```

**Step 3:** Run → FAIL (module undefined).

**Step 4: Implement**

```elixir
defmodule TicketRush.Reservations.Postgres do
  @behaviour TicketRush.Reservations.Strategy
  import Ecto.Query
  alias TicketRush.Repo
  alias TicketRush.Reservations.Reservation

  @impl true
  def hold(seat_id, user_id, opts) do
    key = Keyword.fetch!(opts, :idempotency_key)
    ttl = Keyword.get(opts, :ttl_seconds, 300)

    case find_by_key(key) do
      %Reservation{} = existing -> {:replayed, existing}
      nil -> do_hold(seat_id, user_id, key, ttl)
    end
  end

  @doc "Used by every strategy so replays are answered before any seat arbitration."
  def find_by_key(key), do: Repo.get_by(Reservation, idempotency_key: key)

  defp do_hold(seat_id, user_id, key, ttl) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      # Free the seat if its previous hold already lapsed but Oban has not run yet.
      from(r in Reservation, where: r.seat_id == ^seat_id and r.status == "held" and r.expires_at < ^now)
      |> Repo.update_all(set: [status: "expired"])

      attrs = %{seat_id: seat_id, user_id: user_id, idempotency_key: key,
                expires_at: DateTime.add(now, ttl)}

      case Repo.insert(Reservation.hold_changeset(%Reservation{}, attrs)) do
        {:ok, res} -> res
        {:error, %{errors: [seat_id: {"taken", _}]}} -> Repo.rollback(:taken)
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @impl true
  def confirm(id, user_id) do
    now = DateTime.utc_now()
    case Repo.get_by(Reservation, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      %{status: "held", expires_at: exp} = r ->
        if DateTime.compare(exp, now) == :gt,
          do: r |> Ecto.Changeset.change(status: "confirmed") |> Repo.update(),
          else: {:error, :expired}
      _ -> {:error, :not_held}
    end
  end

  @impl true
  def release(id) do
    case Repo.get(Reservation, id) do
      nil -> {:error, :not_found}
      r -> r |> Ecto.Changeset.change(status: "cancelled") |> Repo.update()
    end
  end
end
```

Create `TicketRush.Reservations` (facade) with `def strategy, do: Application.get_env(:ticket_rush, :reservation_strategy, TicketRush.Reservations.Postgres)` and delegating `hold/3`, `confirm/2`, `release/1`.

**Step 5:** Run `make test ARGS=test/ticket_rush/reservations/postgres_test.exs` → `5 tests, 0 failures`.

**Step 6: Commit** — `git commit -am "feat: add reservation strategy behaviour and postgres strategy"` (after `git add -A`).

---

## Phase 4 — Strategy A (OTP)

> **Elixir Refresher: processes, GenServer, Registry, DynamicSupervisor.**
> Processes are isolated, cheap (~2 KB) and communicate by messages; a GenServer handles *one message at a time*, which is exactly the serialization we want per event. `GenServer.call` is synchronous (with timeout), `cast` is fire-and-forget. `Registry` maps keys to pids (`{:via, Registry, {Name, key}}`). `DynamicSupervisor` starts children on demand. `init/1` must be fast: use `{:continue, :load}` to rehydrate after startup. A crashed GenServer loses its state; the supervisor restarts it with a fresh one — hence rehydration from Postgres.

### Task 6: EventArbiter GenServer

**Files:**
- Create: `api/lib/ticket_rush/reservations/event_arbiter.ex`, `arbiter_supervisor.ex`, `otp.ex`
- Modify: `api/lib/ticket_rush/application.ex`
- Test: `api/test/ticket_rush/reservations/otp_test.exs`

**Design decision (documented deviation):** the design said "persist asynchronously". Write-through *synchronously* inside `handle_call` instead: async persistence can lose acknowledged holds on a crash. The in-memory `MapSet` is a fast path that rejects conflicts without touching the database; the partial index remains the safety net. 🛑 Confirm this deviation with the user before implementing.

**Step 1: Failing tests (contract + OTP-specific)**

```elixir
defmodule TicketRush.Reservations.OtpTest do
  use TicketRush.ReservationStrategyCase, strategy: TicketRush.Reservations.Otp
  alias TicketRush.Reservations.{ArbiterSupervisor, EventArbiter}

  test "arbiter is restarted after a crash and rehydrates held seats", %{seat: seat} do
    {:ok, _} = TicketRush.Reservations.Otp.hold(seat.id, "u1", idempotency_key: "kc")
    pid = EventArbiter.whereis(seat.event_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}, 1_000

    new_pid = wait_for_restart(seat.event_id, pid)
    refute new_pid == pid, "supervisor must start a fresh process"
    assert {:error, :taken} = TicketRush.Reservations.Otp.hold(seat.id, "u2", idempotency_key: "kd"),
           "rehydrated arbiter must still know the seat is held"
  end

  defp wait_for_restart(event_id, old, tries \\ 20) do
    case EventArbiter.whereis(event_id) do
      pid when is_pid(pid) and pid != old -> pid
      _ when tries > 0 -> Process.sleep(25); wait_for_restart(event_id, old, tries - 1)
      _ -> flunk("arbiter was not restarted")
    end
  end
end
```

Note: the Sandbox must run in shared mode for these tests (`Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})` in `setup`), because the GenServer runs in another process. Explain this in `docs/notes/phase4.md`.

**Step 2:** Run → FAIL.

**Step 3: Implement**

```elixir
defmodule TicketRush.Reservations.EventArbiter do
  use GenServer, restart: :transient
  import Ecto.Query
  alias TicketRush.{Repo, Reservations.Postgres}
  alias TicketRush.Events.Seat
  alias TicketRush.Reservations.Reservation

  def start_link(event_id),
    do: GenServer.start_link(__MODULE__, event_id, name: via(event_id))

  def via(event_id), do: {:via, Registry, {TicketRush.ArbiterRegistry, event_id}}
  def whereis(event_id), do: GenServer.whereis(via(event_id))
  def hold(event_id, seat_id, user_id, opts), do: GenServer.call(via(event_id), {:hold, seat_id, user_id, opts})

  @impl true
  def init(event_id), do: {:ok, %{event_id: event_id, taken: MapSet.new()}, {:continue, :rehydrate}}

  @impl true
  def handle_continue(:rehydrate, %{event_id: event_id} = state) do
    taken =
      from(r in Reservation,
        join: s in Seat, on: s.id == r.seat_id,
        where: s.event_id == ^event_id and r.status in ["held", "confirmed"],
        select: r.seat_id)
      |> Repo.all() |> MapSet.new()
    {:noreply, %{state | taken: taken}}
  end

  @impl true
  def handle_call({:hold, seat_id, user_id, opts}, _from, state) do
    # 1. Replays are answered first: a repeated key must return the original
    #    reservation even though its seat is (correctly) marked as taken.
    case Postgres.find_by_key(Keyword.fetch!(opts, :idempotency_key)) do
      %Reservation{} = existing ->
        {:reply, {:replayed, existing}, state}

      nil ->
        # 2. Fast path: memory says taken and the hold has not lapsed.
        if MapSet.member?(state.taken, seat_id) and not expired_in_db?(seat_id) do
          {:reply, {:error, :taken}, state}
        else
          # 3. Slow path: Postgres decides; the partial index is the safety net.
          case Postgres.hold(seat_id, user_id, opts) do
            {:ok, res} -> {:reply, {:ok, res}, %{state | taken: MapSet.put(state.taken, seat_id)}}
            other -> {:reply, other, state}
          end
        end
    end
  end

  # Memory says taken, but the hold may have lapsed: let Postgres decide.
  defp expired_in_db?(seat_id) do
    now = DateTime.utc_now()
    Repo.exists?(from r in Reservation, where: r.seat_id == ^seat_id and r.status == "held" and r.expires_at < ^now)
  end
end
```

```elixir
defmodule TicketRush.Reservations.ArbiterSupervisor do
  def ensure_started(event_id) do
    case DynamicSupervisor.start_child(__MODULE__.Dyn, {TicketRush.Reservations.EventArbiter, event_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
```

`Otp` strategy, `api/lib/ticket_rush/reservations/otp.ex`:

```elixir
defmodule TicketRush.Reservations.Otp do
  @behaviour TicketRush.Reservations.Strategy
  alias TicketRush.{Repo, Events.Seat}
  alias TicketRush.Reservations.{ArbiterSupervisor, EventArbiter, Postgres}

  @impl true
  def hold(seat_id, user_id, opts) do
    %Seat{event_id: event_id} = Repo.get!(Seat, seat_id)
    {:ok, _pid} = ArbiterSupervisor.ensure_started(event_id)
    EventArbiter.hold(event_id, seat_id, user_id, opts)
  end

  # Only the contended path (hold) is serialized by the arbiter; confirming and
  # releasing touch a single row and are safe to delegate to Postgres.
  @impl true
  defdelegate confirm(reservation_id, user_id), to: Postgres

  @impl true
  def release(reservation_id) do
    with {:ok, res} <- Postgres.release(reservation_id) do
      seat = Repo.get!(Seat, res.seat_id)
      # Forget the seat in memory so the fast path does not reject it forever.
      if pid = EventArbiter.whereis(seat.event_id), do: GenServer.cast(pid, {:forget, res.seat_id})
      {:ok, res}
    end
  end
end
```
Add to `EventArbiter`:
```elixir
@impl true
def handle_cast({:forget, seat_id}, state), do: {:noreply, %{state | taken: MapSet.delete(state.taken, seat_id)}}
```
(Expired holds need no cast: the `expired_in_db?/1` check in `handle_call` already covers them.)

**Step 4: Supervision tree** — add to `Application.start/2` children, before `Endpoint`:

```elixir
{Registry, keys: :unique, name: TicketRush.ArbiterRegistry},
{DynamicSupervisor, strategy: :one_for_one, name: TicketRush.Reservations.ArbiterSupervisor.Dyn},
```

**Step 5:** Run `make test ARGS=test/ticket_rush/reservations/otp_test.exs` → all pass.

**Step 6: Observe the processes (study step).** `make iex`, then run:

```elixir
{:ok, _} = TicketRush.Reservations.ArbiterSupervisor.ensure_started(1)
Registry.count(TicketRush.ArbiterRegistry)                         # => 1
pid = TicketRush.Reservations.EventArbiter.whereis(1)
Process.info(pid, [:message_queue_len, :memory])                   # mailbox depth and bytes
DynamicSupervisor.count_children(TicketRush.Reservations.ArbiterSupervisor.Dyn)
Process.exit(pid, :kill); Process.sleep(50)
TicketRush.Reservations.EventArbiter.whereis(1)                    # a NEW pid: the supervisor restarted it
```
(`:observer` is unavailable in Docker.) Record the outputs and what each shows about "let it crash" in `docs/notes/phase4.md`.

**Step 7: Commit** — `git add -A && git commit -m "feat: add OTP event arbiter strategy"`.

---

## Phase 5 — REST API and Channels

> **Elixir Refresher: Plug pipeline, controllers, `action_fallback`, PubSub/Channels.**
> A request flows through the Endpoint and Router plugs into a controller action. `action_fallback` routes any non-conn return (e.g. `{:error, :taken}`) to a `FallbackController`, keeping controllers on the happy path. `Phoenix.PubSub` broadcasts to topics; a Channel subscribes sockets to a topic.

### Task 7: Reservation endpoints

**Files:**
- Create: `api/lib/ticket_rush_web/controllers/reservation_controller.ex`, `fallback_controller.ex`, `event_controller.ex`, `reservation_json.ex`
- Modify: `api/lib/ticket_rush_web/router.ex`
- Test: `api/test/ticket_rush_web/controllers/reservation_controller_test.exs`

**Step 1: Failing tests**

```elixir
defmodule TicketRushWeb.ReservationControllerTest do
  use TicketRushWeb.ConnCase, async: false
  alias TicketRush.Fixtures

  setup %{conn: conn} do
    seat = Fixtures.seat!()
    {:ok, conn: put_req_header(conn, "idempotency-key", "k-#{System.unique_integer([:positive])}"), seat: seat}
  end

  test "201 on first hold, 409 when taken", %{conn: conn, seat: seat} do
    c1 = post(conn, ~p"/api/v1/events/#{seat.event_id}/reservations", %{seat_id: seat.id, user_id: "u1"})
    assert %{"data" => %{"status" => "held"}} = json_response(c1, 201)

    c2 = conn |> put_req_header("idempotency-key", "other") |> post(~p"/api/v1/events/#{seat.event_id}/reservations", %{seat_id: seat.id, user_id: "u2"})
    assert json_response(c2, 409)["error"] == "seat_taken"
  end

  test "400 without Idempotency-Key", %{conn: conn, seat: seat} do
    conn = delete_req_header(conn, "idempotency-key")
    conn = post(conn, ~p"/api/v1/events/#{seat.event_id}/reservations", %{seat_id: seat.id, user_id: "u1"})
    assert json_response(conn, 400)["error"] == "missing_idempotency_key"
  end

  test "replaying the same key returns 200 with the same reservation", %{conn: conn, seat: seat} do
    params = %{seat_id: seat.id, user_id: "u1"}
    c1 = post(conn, ~p"/api/v1/events/#{seat.event_id}/reservations", params)
    id = json_response(c1, 201)["data"]["id"]
    c2 = post(conn, ~p"/api/v1/events/#{seat.event_id}/reservations", params)
    assert json_response(c2, 200)["data"]["id"] == id
  end
end
```

**Step 2:** Run → FAIL (no route).

**Step 3: Implement**

Router:
```elixir
scope "/api/v1", TicketRushWeb do
  pipe_through :api
  get "/events", EventController, :index
  get "/events/:id/seats", EventController, :seats
  post "/events/:event_id/reservations", ReservationController, :create
  post "/reservations/:id/confirm", ReservationController, :confirm
  delete "/reservations/:id", ReservationController, :delete
end
```

`api/lib/ticket_rush_web/controllers/reservation_controller.ex`:

```elixir
defmodule TicketRushWeb.ReservationController do
  use TicketRushWeb, :controller
  alias TicketRush.Reservations
  action_fallback TicketRushWeb.FallbackController

  def create(conn, %{"seat_id" => seat_id, "user_id" => user_id}) do
    with [key] <- get_req_header(conn, "idempotency-key") do
      case Reservations.hold(seat_id, user_id, idempotency_key: key) do
        {:ok, res} -> conn |> put_status(201) |> json(%{data: render(res)})
        {:replayed, res} -> conn |> put_status(200) |> json(%{data: render(res)})
        {:error, _} = error -> error
      end
    else
      [] -> {:error, :missing_idempotency_key}
    end
  end

  def confirm(conn, %{"id" => id, "user_id" => user_id}) do
    with {:ok, res} <- Reservations.confirm(String.to_integer(id), user_id),
         do: json(conn, %{data: render(res)})
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, res} <- Reservations.release(String.to_integer(id)),
         do: json(conn, %{data: render(res)})
  end

  defp render(r), do: %{id: r.id, seat_id: r.seat_id, status: r.status, expires_at: r.expires_at}
end
```

`api/lib/ticket_rush_web/controllers/fallback_controller.ex`:

```elixir
defmodule TicketRushWeb.FallbackController do
  use TicketRushWeb, :controller

  @errors %{
    taken: {409, "seat_taken"}, expired: {410, "hold_expired"}, not_found: {404, "not_found"},
    not_held: {409, "not_held"}, missing_idempotency_key: {400, "missing_idempotency_key"}
  }

  def call(conn, {:error, %Ecto.Changeset{} = cs}) do
    errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
    conn |> put_status(422) |> json(%{error: "invalid", details: errors})
  end

  def call(conn, {:error, reason}) do
    {status, code} = Map.fetch!(@errors, reason)
    conn |> put_status(status) |> json(%{error: code})
  end
end
```

`api/lib/ticket_rush_web/controllers/event_controller.ex` (read-only, public endpoints; pagination is out of scope: an event has at most a few thousand seats):

```elixir
defmodule TicketRushWeb.EventController do
  use TicketRushWeb, :controller
  import Ecto.Query
  alias TicketRush.{Repo, Events.Event, Events.Seat, Reservations.Reservation}

  def index(conn, _params) do
    events =
      Repo.all(from e in Event, order_by: e.starts_at, select: %{id: e.id, name: e.name, starts_at: e.starts_at})

    json(conn, %{data: events})
  end

  def seats(conn, %{"id" => id} = params) do
    seats =
      Repo.all(
        from s in Seat,
          where: s.event_id == ^id,
          left_join: r in Reservation,
          on: r.seat_id == s.id and r.status in ["held", "confirmed"],
          order_by: [s.section, s.row, s.number],
          select: %{id: s.id, section: s.section, row: s.row, number: s.number,
                    price_cents: s.price_cents, taken: not is_nil(r.id)}
      )

    seats = if params["status"] == "available", do: Enum.reject(seats, & &1.taken), else: seats
    json(conn, %{data: seats})
  end
end
```

`api/test/ticket_rush_web/controllers/event_controller_test.exs`:

```elixir
defmodule TicketRushWeb.EventControllerTest do
  use TicketRushWeb.ConnCase, async: false
  alias TicketRush.Fixtures

  test "GET /events lists events", %{conn: conn} do
    event = Fixtures.event!(%{name: "Rock Night"})
    names = json_response(get(conn, "/api/v1/events"), 200)["data"] |> Enum.map(& &1["name"])
    assert event.name in names, "created event must be listed"
  end

  test "GET /events/:id/seats flags taken seats and filters by status", %{conn: conn} do
    [free, taken] = Fixtures.seats!(2)
    {:ok, _} = TicketRush.Reservations.hold(taken.id, "u1", idempotency_key: "ke")

    all = json_response(get(conn, "/api/v1/events/#{free.event_id}/seats"), 200)["data"]
    assert Enum.find(all, &(&1["id"] == taken.id))["taken"] == true, "held seat must be flagged taken"
    assert Enum.find(all, &(&1["id"] == free.id))["taken"] == false

    avail = json_response(get(conn, "/api/v1/events/#{free.event_id}/seats?status=available"), 200)["data"]
    assert Enum.map(avail, & &1["id"]) == [free.id]
  end
end
```
Add both to the Task 7 failing-test run (Step 2) and the passing run (Step 4). Phase 8 later tunes this anti-join with `EXPLAIN ANALYZE`.

**Step 4:** Run → pass. **Step 5:** Commit — `feat: add reservation REST endpoints`.

### Task 8: Seat channel

**Files:**
- Create: `api/lib/ticket_rush_web/channels/event_channel.ex`, `user_socket.ex`
- Modify: `endpoint.ex` (socket mount), `reservations.ex` (broadcast)
- Test: `api/test/ticket_rush_web/channels/event_channel_test.exs`

**Step 1: Failing test**

```elixir
test "joining event:<id> receives seat_held after a hold" do
  seat = TicketRush.Fixtures.seat!()
  {:ok, _, _} = TicketRushWeb.UserSocket |> socket("u", %{}) |> subscribe_and_join(TicketRushWeb.EventChannel, "event:#{seat.event_id}")
  {:ok, _} = TicketRush.Reservations.hold(seat.id, "u1", idempotency_key: "kch")
  assert_push "seat_held", %{seat_id: sid}, 500
  assert sid == seat.id, "payload must identify the seat"
end
```
(`use TicketRushWeb.ChannelCase`.)

**Step 2: Run, expect failure**

Run: `make test ARGS=test/ticket_rush_web/channels/event_channel_test.exs`
Expected: FAIL (`TicketRushWeb.UserSocket` undefined).

**Step 3: Implement**

`api/lib/ticket_rush_web/channels/user_socket.ex`:
```elixir
defmodule TicketRushWeb.UserSocket do
  use Phoenix.Socket
  channel "event:*", TicketRushWeb.EventChannel
  @impl true
  def connect(_params, socket, _info), do: {:ok, socket}
  @impl true
  def id(_socket), do: nil
end
```

`api/lib/ticket_rush_web/channels/event_channel.ex`:
```elixir
defmodule TicketRushWeb.EventChannel do
  use TicketRushWeb, :channel
  @impl true
  def join("event:" <> _event_id, _payload, socket), do: {:ok, socket}
end
```

In `api/lib/ticket_rush_web/endpoint.ex` add `socket "/socket", TicketRushWeb.UserSocket, websocket: true, longpoll: false`.

In `api/lib/ticket_rush/reservations.ex` (the facade), wrap `hold/3` so a *new* hold broadcasts:
```elixir
def hold(seat_id, user_id, opts) do
  case strategy().hold(seat_id, user_id, opts) do
    {:ok, res} = ok ->
      event_id = TicketRush.Repo.get!(TicketRush.Events.Seat, seat_id).event_id
      TicketRushWeb.Endpoint.broadcast("event:#{event_id}", "seat_held", %{seat_id: seat_id})
      ok
    other -> other
  end
end
```
(The extra `Repo.get!` is acceptable now; Phase 8 revisits it if the benchmark shows it matters.)

**Step 4: Run, expect pass**

Run: `make test ARGS=test/ticket_rush_web/channels/event_channel_test.exs`
Expected: `1 test, 0 failures`.

**Step 5:** Commit — `feat: broadcast seat updates over channels`.

---

## Phase 6 — Oban and Broadway

> **Elixir Refresher: Oban and Broadway.**
> Oban stores jobs in Postgres (table `oban_jobs`), so enqueue can happen in the *same transaction* as your data change (`Oban.insert/2` inside `Ecto.Multi`) — jobs never exist without the data that justifies them. `perform/1` returns `:ok`, `{:error, _}` (retry with backoff), or `{:cancel, _}`. Broadway is a pipeline of producer → processors (concurrent, per-message) → batchers (grouped writes) with built-in backpressure and acknowledgements.

### Task 9: Expiration job (Oban)

**Files:**
- Create: migration `*_add_oban_jobs_table.exs`, `api/lib/ticket_rush/workers/expire_hold.ex`
- Modify: `mix.exs` (`{:oban, "~> 2.19"}`), `config/config.exs`, `config/test.exs` (`config :ticket_rush, Oban, testing: :manual`), `application.ex` (`{Oban, Application.fetch_env!(:ticket_rush, Oban)}`)
- Test: `api/test/ticket_rush/workers/expire_hold_test.exs`

**Step 1: Failing test**

```elixir
defmodule TicketRush.Workers.ExpireHoldTest do
  use TicketRush.DataCase, async: true
  use Oban.Testing, repo: TicketRush.Repo
  alias TicketRush.{Fixtures, Repo, Reservations.Reservation}
  alias TicketRush.Workers.ExpireHold

  test "expires a lapsed hold" do
    seat = Fixtures.seat!()
    {:ok, res} = TicketRush.Reservations.Postgres.hold(seat.id, "u1", idempotency_key: "k", ttl_seconds: -1)
    assert :ok = perform_job(ExpireHold, %{"reservation_id" => res.id})
    assert Repo.get!(Reservation, res.id).status == "expired"
  end

  test "is idempotent and never touches a confirmed reservation" do
    seat = Fixtures.seat!()
    {:ok, res} = TicketRush.Reservations.Postgres.hold(seat.id, "u1", idempotency_key: "k")
    {:ok, _} = TicketRush.Reservations.Postgres.confirm(res.id, "u1")
    assert :ok = perform_job(ExpireHold, %{"reservation_id" => res.id})
    assert :ok = perform_job(ExpireHold, %{"reservation_id" => res.id}), "second run must also be :ok"
    assert Repo.get!(Reservation, res.id).status == "confirmed", "confirmed must survive expiry job"
  end
end
```

Oban job args are stored as JSON, so they are always **string-keyed** inside `perform/1`; the tests use string keys to match what production sees.

**Step 2:** Run → FAIL. **Step 3: Implement**

```elixir
defmodule TicketRush.Workers.ExpireHold do
  use Oban.Worker, queue: :holds, max_attempts: 5
  import Ecto.Query
  alias TicketRush.{Repo, Reservations.Reservation}

  @impl true
  def perform(%Oban.Job{args: %{"reservation_id" => id}}) do
    now = DateTime.utc_now()
    {n, _} =
      from(r in Reservation, where: r.id == ^id and r.status == "held" and r.expires_at <= ^now)
      |> Repo.update_all(set: [status: "expired"])
    if n > 0, do: broadcast_release(id)
    :ok
  end
  defp broadcast_release(_id), do: :ok  # wired to Channels in Step 5
end
```
`perform/1` is above; remove the `broadcast_release/1` placeholder and instead broadcast for real. Replace the `if n > 0` line with:

```elixir
if n > 0 do
  seat_id = Repo.one!(from r in Reservation, where: r.id == ^id, select: r.seat_id)
  event_id = Repo.one!(from s in TicketRush.Events.Seat, where: s.id == ^seat_id, select: s.event_id)
  TicketRushWeb.Endpoint.broadcast("event:#{event_id}", "seat_released", %{seat_id: seat_id})
end
:ok
```
and delete the `defp broadcast_release` line.

**Step 4:** Enqueue on hold: in `Postgres.do_hold`, after insert, `Oban.insert!(ExpireHold.new(%{reservation_id: res.id}, scheduled_at: res.expires_at))` inside the same `Repo.transaction` (Oban config: `queues: [holds: 20]`). Add a test asserting `assert_enqueued worker: ExpireHold, args: %{reservation_id: res.id}`.

**Step 5:** Run all tests → pass. **Step 6:** Commit — `feat: expire holds with oban`.

### Task 10: Audit pipeline (Broadway)

**Files:**
- Create: migration `*_create_audit_events.exs` (partitioned), `api/lib/ticket_rush/audit/pipeline.ex`, `audit.ex`
- Modify: `mix.exs` (`{:broadway, "~> 1.1"}`), `application.ex`
- Test: `api/test/ticket_rush/audit/pipeline_test.exs`

**Step 1: Migration (raw SQL because Ecto has no partition DSL)**

```elixir
def up do
  execute """
  CREATE TABLE audit_events (
    id bigserial, occurred_at timestamptz NOT NULL, kind text NOT NULL,
    seat_id bigint, user_id text, payload jsonb NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, occurred_at)
  ) PARTITION BY RANGE (occurred_at)
  """
  execute "CREATE TABLE audit_events_default PARTITION OF audit_events DEFAULT"
end
def down, do: execute("DROP TABLE audit_events")
```
Monthly partitions are added in Phase 8.

**Step 2: Failing test**

```elixir
test "batches messages into audit_events" do
  ref = Broadway.test_message(TicketRush.Audit.Pipeline, %{kind: "seat_held", seat_id: 1, user_id: "u1"})
  assert_receive {:ack, ^ref, [_], []}, 2_000
  assert %{rows: [[1]]} = TicketRush.Repo.query!("SELECT count(*) FROM audit_events WHERE kind='seat_held'")
end
```
Use `Ecto.Adapters.SQL.Sandbox` shared mode. Config the pipeline with `Broadway.DummyProducer` under `Mix.env() == :test` via application env.

**Step 3: Implement** `api/lib/ticket_rush/audit/pipeline.ex` and `audit.ex`

```elixir
defmodule TicketRush.Audit.Pipeline do
  use Broadway
  alias Broadway.Message

  def start_link(opts) do
    producer = Keyword.get(opts, :producer, {TicketRush.Audit.Producer, []})
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [module: producer, concurrency: 1],
      processors: [default: [concurrency: 4]],
      batchers: [db: [batch_size: 100, batch_timeout: 500, concurrency: 2]])
  end

  @impl true
  def handle_message(_processor, %Message{} = message, _ctx), do: Message.put_batcher(message, :db)

  @impl true
  def handle_batch(:db, messages, _batch_info, _ctx) do
    now = DateTime.utc_now()
    rows = for %Message{data: d} <- messages,
               do: %{occurred_at: now, kind: d.kind, seat_id: d[:seat_id], user_id: d[:user_id], payload: %{}}
    TicketRush.Repo.insert_all("audit_events", rows)
    messages
  end
end
```

Producer decision (🛑 confirm with the user; recommended default below): an in-process `GenStage` producer fed by `Audit.record/1`, using the `{:gen_stage, "~> 1.2"}` dependency:

```elixir
defmodule TicketRush.Audit.Producer do
  use GenStage
  def start_link(_), do: GenStage.start_link(__MODULE__, :ok)
  @impl true
  def init(:ok), do: {:producer, %{queue: :queue.new(), demand: 0}}
  @impl true
  def handle_demand(d, s), do: dispatch(%{s | demand: s.demand + d})
  @impl true
  def handle_info({:event, e}, s), do: dispatch(%{s | queue: :queue.in(e, s.queue)})

  defp dispatch(%{queue: q, demand: d} = s) do
    {items, q} = take(q, d, [])
    {:noreply, items, %{s | queue: q, demand: d - length(items)}}
  end
  defp take(q, 0, acc), do: {Enum.reverse(acc), q}
  defp take(q, n, acc) do
    case :queue.out(q) do
      {{:value, e}, q2} -> take(q2, n - 1, [%Broadway.Message{data: e, acknowledger: Broadway.NoopAcknowledger.init()} | acc])
      {:empty, q2} -> {Enum.reverse(acc), q2}
    end
  end
end
```
`Audit.record(event)` sends `{:event, event}` to the producer pid found via `Broadway.producer_names(TicketRush.Audit.Pipeline)`. In `config/test.exs` start the pipeline with `producer: {Broadway.DummyProducer, []}`. Add `{TicketRush.Audit.Pipeline, Application.get_env(:ticket_rush, :audit_pipeline_opts, [])}` to the supervision tree. Study note: the trade-off versus polling Postgres is durability — the in-process queue loses events on a crash; document it in `docs/notes/phase6.md`.

**Step 4–5:** Run → pass; commit `feat: batch audit events with broadway`.

---

## Phase 7 — Property tests and benchmark

> **Elixir Refresher: Task, concurrency primitives, StreamData.**
> `Task.async_stream/3` runs a function over an enumerable with bounded concurrency and ordered results. StreamData generates random inputs and *shrinks* failures to a minimal case. Property-based thinking: state an invariant ("no seat sold twice"), not examples.

### Task 11: Concurrency invariant property test

**Files:** Modify `mix.exs` (`{:stream_data, "~> 1.1", only: [:dev, :test]}`); Create `api/test/ticket_rush/reservations/concurrency_property_test.exs`

**Step 1: Write the test (runs against both strategies)**

```elixir
defmodule TicketRush.Reservations.ConcurrencyPropertyTest do
  use TicketRush.DataCase, async: false
  use ExUnitProperties
  alias TicketRush.{Fixtures, Repo}

  # The default Sandbox serializes everything on ONE connection, which would hide
  # real database races. These properties must run on real, independent connections:
  # switch the sandbox to :auto and clean up by hand.
  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      Repo.query!("TRUNCATE reservations, seats, events RESTART IDENTITY CASCADE")
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)
    :ok
  end

  for strategy <- [TicketRush.Reservations.Postgres, TicketRush.Reservations.Otp] do
    @strategy strategy
    property "#{inspect(strategy)}: never more winners than seats, never a seat twice" do
      check all seats_n <- integer(1..5), buyers_n <- integer(1..40), max_runs: 25 do
        seats = Fixtures.seats!(seats_n)

        results =
          1..buyers_n
          |> Task.async_stream(fn i ->
            seat = Enum.at(seats, rem(i, seats_n))
            {seat.id, @strategy.hold(seat.id, "u#{i}", idempotency_key: "k-#{System.unique_integer([:positive])}")}
          end, max_concurrency: 40, ordered: false)
          |> Enum.map(fn {:ok, r} -> r end)

        winners = for {seat_id, {:ok, _}} <- results, do: seat_id
        assert length(winners) == length(Enum.uniq(winners)), "a seat was sold twice: #{inspect(winners)}"
        assert length(winners) <= seats_n, "more winners than seats"
        assert length(winners) == min(seats_n, buyers_n), "a free seat was wrongly rejected"
      end
    end
  end
end
```
Add `Fixtures.seats!/1`. Note: with `buyers_n < seats_n` the last assertion expects exactly `min(...)` only when buyers cover distinct seats — `rem(i, seats_n)` ensures buyers 1..n hit distinct seats first; if the assertion proves wrong for some shape, fix the *property*, not the code, and record why in `docs/notes/phase8.md`.

**Step 2:** Run `make test ARGS=test/ticket_rush/reservations/concurrency_property_test.exs` → pass (≥ 25 runs per strategy).

**Step 3 (study):** Temporarily drop the partial index in a scratch migration and watch Strategy B's property fail; read the shrunk counterexample. Revert. Record in notes.

**Step 4:** Commit — `test: add concurrency property tests for both strategies`.

### Task 12: Benchmark harness

**Files:** Create `bench/package.json`, `bench/src/run.ts`, `bench/README.md`; `api/config/runtime.exs` reads `RESERVATION_STRATEGY` (`postgres|otp`)

**Step 1: Seed route** (dev/test only). In `router.ex`:

```elixir
if Mix.env() != :prod do
  scope "/api/v1/dev", TicketRushWeb do
    pipe_through :api
    post "/seed", DevController, :seed
  end
end
```
`api/lib/ticket_rush_web/controllers/dev_controller.ex`:
```elixir
defmodule TicketRushWeb.DevController do
  use TicketRushWeb, :controller
  alias TicketRush.{Repo, Events.Event, Events.Seat}

  def seed(conn, %{"seats" => n}) do
    Repo.query!("TRUNCATE reservations, seats, events RESTART IDENTITY CASCADE")
    event = Repo.insert!(%Event{name: "Bench", starts_at: ~U[2030-01-01 20:00:00Z]})
    seats = for i <- 1..n, do: Repo.insert!(%Seat{event_id: event.id, section: "A", row: "1", number: i, price_cents: 1000})
    json(conn, %{event_id: event.id, seat_ids: Enum.map(seats, & &1.id)})
  end
end
```
In `config/runtime.exs`: `config :ticket_rush, :reservation_strategy, (case System.get_env("RESERVATION_STRATEGY", "postgres") do "otp" -> TicketRush.Reservations.Otp; _ -> TicketRush.Reservations.Postgres end)`.

**Step 2: `bench/src/run.ts`** (`bench/package.json`: `"type": "module"`, dev deps `tsx`, `typescript`, `@types/node`; this is the project's only TypeScript, kept as a typed load-testing tool)

```ts
const API = process.env.API_URL ?? "http://api:4000";
const SEATS = Number(process.env.SEATS ?? 100);
const BUYERS = Number(process.env.BUYERS ?? 5000);
const CONCURRENCY = Number(process.env.CONCURRENCY ?? 200);

const seed = (await (await fetch(`${API}/api/v1/dev/seed`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ seats: SEATS }),
})).json()) as { event_id: number; seat_ids: number[] };

const latencies: number[] = [];
let created = 0, taken = 0, other = 0, next = 0;

async function buyer(i: number) {
  const seatId = seed.seat_ids[i % SEATS]!; // heavy contention: many buyers per seat
  const t0 = performance.now();
  const res = await fetch(`${API}/api/v1/events/${seed.event_id}/reservations`, {
    method: "POST",
    headers: { "content-type": "application/json", "idempotency-key": `bench-${i}` },
    body: JSON.stringify({ seat_id: seatId, user_id: `u${i}` }),
  });
  latencies.push(performance.now() - t0);
  if (res.status === 201) created++; else if (res.status === 409) taken++; else other++;
}

const started = performance.now();
// Bounded worker pool: CONCURRENCY loops pull the next buyer until none are left.
await Promise.all(Array.from({ length: CONCURRENCY }, async () => {
  while (next < BUYERS) await buyer(next++);
}));
const seconds = (performance.now() - started) / 1000;

latencies.sort((a, b) => a - b);
const pct = (p: number) => latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * p))]!.toFixed(1);
console.log({ strategy: process.env.RESERVATION_STRATEGY ?? "postgres", buyers: BUYERS, seats: SEATS,
  created, taken, other, oversold: Math.max(0, created - SEATS),
  p50: pct(0.5), p95: pct(0.95), p99: pct(0.99), rps: Math.round(BUYERS / seconds) });
if (created > SEATS) { console.error("OVERSOLD"); process.exit(1); }
```

**Step 3:** Run each strategy (the compose `api` service reads `RESERVATION_STRATEGY` from the environment; add `RESERVATION_STRATEGY: ${RESERVATION_STRATEGY:-postgres}` to its `environment`; use the `bench` compose service defined in Task 1):
```bash
RESERVATION_STRATEGY=postgres docker compose up -d --force-recreate api && docker compose run --rm bench sh -c "npm i && npx tsx src/run.ts"
RESERVATION_STRATEGY=otp      docker compose up -d --force-recreate api && docker compose run --rm bench npx tsx src/run.ts
```
Expected: each prints an object with `oversold: 0` and `created: 100`.

**Step 3:** Write results table + interpretation (why one wins at which contention level) into `docs/benchmark.md`. 🛑 Share the numbers with the user and discuss before concluding.

**Step 4:** Commit — `feat: add strategy comparison benchmark`.

---

## Phase 8 — PostgreSQL optimization

> **Postgres Refresher.** `EXPLAIN (ANALYZE, BUFFERS)` shows the real plan and timings. A partial index only contains rows matching its predicate, so it is small and fast for that predicate. Range partitioning lets queries prune partitions and makes retention a cheap `DROP TABLE`. Never create indexes on hot tables with a plain `CREATE INDEX` in production: use `CONCURRENTLY` (in Ecto: `@disable_ddl_transaction true` + `concurrently: true`).

### Task 13: Measure, index, partition

**Files:** Create `docs/postgres-tuning.md`, migrations `*_add_audit_partitions.exs`, `*_add_seat_status_index.exs`

**Step 1: Perf seed.** `api/priv/repo/seeds_perf.exs`:

```elixir
TicketRush.Repo.query!("""
INSERT INTO events (name, starts_at, status, inserted_at, updated_at)
SELECT 'Event ' || g, now() + interval '30 days', 'on_sale', now(), now() FROM generate_series(1, 200) g
""")
TicketRush.Repo.query!("""
INSERT INTO seats (event_id, section, row, number, price_cents, inserted_at, updated_at)
SELECT e.id, 'S' || (n % 10), ((n / 100) + 1)::text, n, 1000, now(), now()
FROM events e, generate_series(1, 1000) n
""")
TicketRush.Repo.query!("""
INSERT INTO reservations (seat_id, user_id, status, expires_at, idempotency_key, inserted_at, updated_at)
SELECT s.id, 'u' || s.id,
       CASE WHEN s.id % 3 = 0 THEN 'confirmed' WHEN s.id % 7 = 0 THEN 'held' ELSE 'expired' END,
       now() + ((s.id % 120) || ' seconds')::interval, 'perf-' || s.id, now(), now()
FROM seats s WHERE s.id % 5 <> 0
""")
TicketRush.Repo.query!("ANALYZE")
```
Run: `docker compose run --rm api mix run priv/repo/seeds_perf.exs`. Expected: no error; 200 events × 1000 seats = 200k seats and about 160k reservations. Check with `make psql` then `SELECT count(*) FROM seats;` → `200000`.

**Step 2: Capture BEFORE plans** with `make psql`; paste the full output into `docs/postgres-tuning.md` under "Before":

```sql
-- (a) available seats for one event: anti-join against active reservations
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.id FROM seats s
WHERE s.event_id = 42
  AND NOT EXISTS (SELECT 1 FROM reservations r WHERE r.seat_id = s.id AND r.status IN ('held','confirmed'));

-- (b) holds expiring in the next minute
EXPLAIN (ANALYZE, BUFFERS)
SELECT id FROM reservations WHERE status = 'held' AND expires_at < now() + interval '1 minute';

-- (c) reservations of one event through the JOIN
EXPLAIN (ANALYZE, BUFFERS)
SELECT r.id FROM reservations r JOIN seats s ON s.id = r.seat_id WHERE s.event_id = 42;
```
Success criterion: you can state, per query, the scan type (Seq/Index/Bitmap), actual time and buffers read.

**Step 3: Change one thing at a time, then capture AFTER plans.** Migration `*_add_seat_covering_index.exs`:

```elixir
defmodule TicketRush.Repo.Migrations.AddSeatCoveringIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:seats, [:event_id],
             include: [:section, :row, :number, :price_cents],
             name: :seats_event_covering_idx, concurrently: true)
  end
end
```
Rule: add an index only if its BEFORE plan shows a Seq Scan or a large `Buffers: shared read` AND the AFTER plan shows an improvement. Record rejected candidates and the reason too. (The partial `reservations_held_expiry_idx` from Task 3 should already serve query (b); confirm that in the plan.)

**Step 4: Audit partitions.** Migration `*_add_audit_partitions.exs`:

```elixir
def up do
  for offset <- 0..2 do
    execute """
    DO $$ DECLARE s date := date_trunc('month', now() + interval '#{offset} month')::date;
    BEGIN
      EXECUTE format('CREATE TABLE IF NOT EXISTS audit_events_%s PARTITION OF audit_events FOR VALUES FROM (%L) TO (%L)',
        to_char(s, 'YYYY_MM'), s, (s + interval '1 month')::date);
    END $$;
    """
  end
end
def down, do: :ok
```
Verify pruning: `EXPLAIN SELECT * FROM audit_events WHERE occurred_at >= date_trunc('month', now());` → the plan must list only one `audit_events_YYYY_MM` partition. Paste it into the doc.

**Step 5: Decide on `reservations.event_id`.** Keep it out unless query (c) is demonstrably the bottleneck (> 100 ms on 1M rows). 🛑 Present the numbers to the user and decide together before denormalizing.

**Step 6: Commit** — `git add -A && git commit -m "perf: add indexes and audit partitions with documented plans"`

---

## Phase 9 — Production hardening of the API

> **Elixir Refresher: Plug, ETS and Telemetry.**
> A `Plug` is a function (or module with `init/1` + `call/2`) from `conn` to `conn`; pipelines are lists of plugs and a plug may halt the request (`halt/1`). ETS is an in-memory table shared by all processes on the node, with atomic counters (`:ets.update_counter/4`), so it is the idiomatic home for rate-limit counters. `:telemetry.execute/3` emits an event that any handler can subscribe to, decoupling instrumentation from consumers (metrics, logs).

Context: clients reach the Phoenix API directly, with no proxy layer in between, so the API itself must defend against abuse and overload. Phase 9 also replaces the loose `user_id` in request bodies with real authentication.

### Task 14: Rate limiting and load shedding

**Files:**
- Create: `api/lib/ticket_rush_web/plugs/rate_limit.ex`, `api/lib/ticket_rush/rate_limiter.ex`
- Modify: `api/lib/ticket_rush_web/router.ex`, `api/lib/ticket_rush/reservations/event_arbiter.ex`, `api/lib/ticket_rush/application.ex`, `api/lib/ticket_rush_web/controllers/fallback_controller.ex`
- Test: `api/test/ticket_rush_web/plugs/rate_limit_test.exs`, `api/test/ticket_rush/reservations/overload_test.exs`

**Step 1: Failing tests**

```elixir
defmodule TicketRushWeb.Plugs.RateLimitTest do
  use TicketRushWeb.ConnCase, async: false
  alias TicketRushWeb.Plugs.RateLimit

  setup do
    TicketRush.RateLimiter.reset()
    :ok
  end

  test "allows up to the limit then answers 429 with Retry-After" do
    opts = RateLimit.init(limit: 3, window_ms: 60_000)
    conns = for _ <- 1..4, do: RateLimit.call(Phoenix.ConnTest.build_conn(), opts)
    assert Enum.map(conns, & &1.status) == [nil, nil, nil, 429], "4th request in the window must be limited"
    assert [_] = Plug.Conn.get_resp_header(List.last(conns), "retry-after")
  end

  test "different keys have independent buckets" do
    opts = RateLimit.init(limit: 1, window_ms: 60_000)
    a = %{Phoenix.ConnTest.build_conn() | remote_ip: {10, 0, 0, 1}}
    b = %{Phoenix.ConnTest.build_conn() | remote_ip: {10, 0, 0, 2}}
    refute RateLimit.call(a, opts).halted
    refute RateLimit.call(b, opts).halted, "another IP must not share the first IP's bucket"
  end
end
```

```elixir
defmodule TicketRush.Reservations.OverloadTest do
  use TicketRush.DataCase, async: false
  alias TicketRush.{Fixtures, Reservations.EventArbiter}

  test "arbiter sheds load when its mailbox exceeds the threshold" do
    seat = Fixtures.seat!()
    {:ok, pid} = TicketRush.Reservations.ArbiterSupervisor.ensure_started(seat.event_id)
    :sys.suspend(pid)                       # the arbiter stops consuming its mailbox
    for i <- 1..60, do: send(pid, {:noise, i})
    assert {:error, :overloaded} = EventArbiter.hold(seat.event_id, seat.id, "u1", idempotency_key: "ko"),
           "a hot event must reject instead of queueing without bound"
    :sys.resume(pid)
  end
end
```

**Step 2:** Run both files → FAIL (modules missing).

**Step 3: Implement**

`api/lib/ticket_rush/rate_limiter.ex` (ETS fixed window, owned by a GenServer so the table survives caller crashes):

```elixir
defmodule TicketRush.RateLimiter do
  use GenServer
  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def reset, do: :ets.delete_all_objects(@table)

  @doc "Returns {:allow, count} or {:deny, retry_after_seconds}."
  def hit(key, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    bucket = div(now, window_ms)
    expires = (bucket + 1) * window_ms
    # Row: {{key, bucket}, count, expires_at_ms}. update_counter creates it atomically on first hit.
    count = :ets.update_counter(@table, {key, bucket}, {2, 1}, {{key, bucket}, 0, expires})
    if count <= limit, do: {:allow, count}, else: {:deny, max(1, div(expires - now, 1000))}
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :timer.send_interval(60_000, :sweep)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Delete every row whose window already ended; works for any window size.
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    {:noreply, state}
  end
end
```
Add a test: hit once with `window_ms: 1`, `Process.sleep(5)`, `send(Process.whereis(TicketRush.RateLimiter), :sweep)`, call `:sys.get_state/1` to sync, then assert `:ets.tab2list(TicketRush.RateLimiter) == []`.

`api/lib/ticket_rush_web/plugs/rate_limit.ex`:
```elixir
defmodule TicketRushWeb.Plugs.RateLimit do
  import Plug.Conn
  def init(opts), do: %{limit: opts[:limit], window_ms: Keyword.get(opts, :window_ms, 1000), by: Keyword.get(opts, :by, :ip)}

  def call(conn, %{limit: limit, window_ms: window_ms, by: by}) do
    # Plug options are frozen at compile time, but RATE_LIMIT is a runtime setting: resolve it per request.
    limit = limit || Application.fetch_env!(:ticket_rush, :rate_limit)
    key = {by, identity(conn, by)}
    case TicketRush.RateLimiter.hit(key, limit, window_ms) do
      {:allow, _} -> conn
      {:deny, retry} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry))
        |> put_resp_content_type("application/json")
        |> send_resp(429, ~s({"error":"rate_limited"}))
        |> halt()
    end
  end

  defp identity(conn, :user), do: conn.assigns.current_user_id
  defp identity(conn, :ip), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
```
Add `TicketRush.RateLimiter` to the supervision tree (before `Endpoint`). In `config/config.exs` set `config :ticket_rush, :rate_limit, 50`; `config/test.exs` sets it to `10_000` so unrelated tests are unaffected; `runtime.exs` overrides it only when the `RATE_LIMIT` env var exists (Task 17) so the benchmark can raise it. In the router add `plug TicketRushWeb.Plugs.RateLimit` (no options, keyed by IP) at the end of the `:api` pipeline, which also protects the public register/login endpoints from brute force. Task 15 adds a second instance, `plug TicketRushWeb.Plugs.RateLimit, by: :user`, right *after* `Authenticate` in the `:authenticated` pipeline, so authenticated traffic is limited per user (order matters: the user is unknown before `Authenticate` runs). In `endpoint.ex` add `plug Plug.RewriteOn, [:x_forwarded_for, :x_forwarded_proto]` before the router: in production the app sits behind Fly's proxy, and without it every client shares the proxy's IP and one bucket.

Load shedding in `EventArbiter`:
```elixir
@max_mailbox 50
def hold(event_id, seat_id, user_id, opts) do
  pid = GenServer.whereis(via(event_id))
  case Process.info(pid, :message_queue_len) do
    {:message_queue_len, n} when n > @max_mailbox -> {:error, :overloaded}
    _ -> GenServer.call(via(event_id), {:hold, seat_id, user_id, opts}, 3_000)
  end
catch
  :exit, {:timeout, _} -> {:error, :overloaded}
end
```
FallbackController: add `overloaded: {503, "overloaded"}` to `@errors` and a `put_resp_header("retry-after", "1")` for that code.

**Step 4:** Run `make test ARGS=test/ticket_rush_web/plugs test/ticket_rush/reservations/overload_test.exs` → `0 failures`.

**Step 5: Commit** — `git add -A && git commit -m "feat: add rate limiting and arbiter load shedding"`

### Task 15: Authentication (register, login, signed token)

**Files:**
- Create: migration `*_create_users.exs`, `api/lib/ticket_rush/accounts.ex`, `api/lib/ticket_rush/accounts/user.ex`, `api/lib/ticket_rush_web/plugs/authenticate.ex`, `api/lib/ticket_rush_web/controllers/session_controller.ex`, `user_controller.ex`
- Modify: `mix.exs` (`{:bcrypt_elixir, "~> 3.2"}`), `router.ex`, `reservation_controller.ex`, `user_socket.ex`, `bench/src/run.ts`, existing controller/channel tests
- Test: `api/test/ticket_rush/accounts_test.exs`, `api/test/ticket_rush_web/plugs/authenticate_test.exs`

**Step 1: Failing tests**

```elixir
defmodule TicketRush.AccountsTest do
  use TicketRush.DataCase, async: true
  alias TicketRush.Accounts

  test "register stores a hash, never the password" do
    assert {:ok, user} = Accounts.register(%{email: "a@b.co", password: "correct horse"})
    refute user.password_hash == "correct horse", "password must be hashed"
    assert String.starts_with?(user.password_hash, "$2b$")
  end

  test "login returns a verifiable token only for valid credentials" do
    {:ok, user} = Accounts.register(%{email: "a@b.co", password: "correct horse"})
    assert {:ok, token} = Accounts.login("a@b.co", "correct horse")
    assert {:ok, user.id} == Accounts.verify_token(token)
    assert {:error, :invalid_credentials} = Accounts.login("a@b.co", "wrong")
    assert {:error, :invalid_credentials} = Accounts.login("nobody@b.co", "x"), "unknown email must look identical"
  end

  test "register rejects short passwords and duplicate emails" do
    assert {:error, cs} = Accounts.register(%{email: "a@b.co", password: "short"})
    assert %{password: [_]} = errors_on(cs)
    {:ok, _} = Accounts.register(%{email: "a@b.co", password: "correct horse"})
    assert {:error, cs} = Accounts.register(%{email: "a@b.co", password: "correct horse"})
    assert %{email: ["has already been taken"]} = errors_on(cs)
  end
end
```

```elixir
defmodule TicketRushWeb.Plugs.AuthenticateTest do
  use TicketRushWeb.ConnCase, async: true
  alias TicketRushWeb.Plugs.Authenticate

  test "401 without a token, assigns current_user_id with a valid one", %{conn: conn} do
    {:ok, user} = TicketRush.Accounts.register(%{email: "a@b.co", password: "correct horse"})
    {:ok, token} = TicketRush.Accounts.login("a@b.co", "correct horse")

    assert Authenticate.call(conn, []).status == 401
    ok = conn |> put_req_header("authorization", "Bearer #{token}") |> Authenticate.call([])
    assert ok.assigns.current_user_id == user.id
  end
end
```

**Step 2:** Run → FAIL.

**Step 3: Implement**

Migration:
```elixir
create table(:users) do
  add :email, :citext, null: false
  add :password_hash, :string, null: false
  timestamps()
end
create unique_index(:users, [:email])
```
(Run `execute "CREATE EXTENSION IF NOT EXISTS citext"` first, in `up/0`.) `reservations.user_id` stays a string column and now stores `to_string(user.id)`.

`Accounts`:
```elixir
defmodule TicketRush.Accounts do
  alias TicketRush.{Repo, Accounts.User}
  @salt "user auth"
  @max_age 86_400

  def register(attrs), do: %User{} |> User.registration_changeset(attrs) |> Repo.insert()

  def login(email, password) do
    user = Repo.get_by(User, email: email)
    cond do
      user && Bcrypt.verify_pass(password, user.password_hash) ->
        {:ok, Phoenix.Token.sign(TicketRushWeb.Endpoint, @salt, user.id)}
      true ->
        Bcrypt.no_user_verify()   # constant-ish time: no user-enumeration oracle
        {:error, :invalid_credentials}
    end
  end

  def verify_token(token), do: Phoenix.Token.verify(TicketRushWeb.Endpoint, @salt, token, max_age: @max_age)
end
```
`User.registration_changeset/2`: cast `[:email, :password]`, `validate_required`, `validate_format(:email, ~r/^[^\s]+@[^\s]+$/)`, `validate_length(:password, min: 8)`, `unique_constraint(:email)`, then put `password_hash` from `Bcrypt.hash_pwd_salt/1` and delete the virtual `password` field (declare `field :password, :string, virtual: true, redact: true`). Set `config :bcrypt_elixir, :log_rounds, 4` in `config/test.exs` so tests stay fast.

`Authenticate` plug: read `authorization` header, `"Bearer " <> token` → `Accounts.verify_token/1`; on `{:ok, id}` `assign(conn, :current_user_id, id)`; otherwise respond 401 `{"error":"unauthorized"}` and `halt/1`.

Router: public `POST /api/v1/users` (register) and `POST /api/v1/sessions` (login → `{"token": ...}`); everything under reservations goes through an `:authenticated` pipeline (`plug TicketRushWeb.Plugs.Authenticate`). Reservation controller uses `conn.assigns.current_user_id` instead of the `user_id` param (drop `user_id` from params; update the three controller tests to log in first via a `setup` helper `log_in(conn)` placed in `ConnCase`). Socket: `UserSocket.connect/3` verifies the `token` param with `Accounts.verify_token/1` and assigns `current_user_id`, refusing the connection (`:error`) otherwise; update the channel test to pass a token. In `bench/src/run.ts` register N users once (or one user per worker) and send `Authorization: Bearer ...`; See Task 14 for why the per-user `RateLimit` comes after `Authenticate`.

`bench/src/run.ts` changes (each worker is one user, as real clients are; run with `RATE_LIMIT=100000` on the API so the benchmark measures the strategies, not the limiter):

```ts
const runId = Date.now();
const post = (path: string, body: unknown, token?: string) =>
  fetch(`${API}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });

async function login(i: number): Promise<string> {
  const creds = { email: `bench-${runId}-${i}@example.com`, password: "correct horse battery" };
  await post("/api/v1/users", creds);
  const res = await post("/api/v1/sessions", creds);
  return ((await res.json()) as { token: string }).token;
}

// bcrypt is deliberately slow; register users in small batches so setup does not look like load.
const tokens: string[] = [];
for (let i = 0; i < CONCURRENCY; i += 20) {
  tokens.push(...(await Promise.all(Array.from({ length: Math.min(20, CONCURRENCY - i) }, (_, k) => login(i + k)))));
}
```
In `buyer(i, token)` replace the `fetch` with `post(`/api/v1/events/${seed.event_id}/reservations`, { seat_id: seatId }, token)` plus the `idempotency-key` header (extend `post` to accept extra headers), and have worker `w` of the pool call `buyer(next++, tokens[w]!)`. The seed route does not need a token (dev only).

**Step 4:** Run `make test` → `0 failures`.

**Step 5: Commit** — `git add -A && git commit -m "feat: add registration, login and token authentication"`

### Task 16: Health checks, telemetry and structured logs

**Files:**
- Create: `api/lib/ticket_rush_web/controllers/health_controller.ex`, `api/lib/ticket_rush/telemetry_logger.ex`
- Modify: `router.ex`, `application.ex`, `reservations.ex`, `mix.exs` (`{:logger_json, "~> 6.0"}`), `config/prod.exs`
- Test: `api/test/ticket_rush_web/controllers/health_controller_test.exs`, `api/test/ticket_rush/telemetry_test.exs`

**Step 1: Failing tests**

```elixir
defmodule TicketRushWeb.HealthControllerTest do
  use TicketRushWeb.ConnCase, async: true

  test "GET /health is always 200 (liveness)", %{conn: conn} do
    assert json_response(get(conn, "/health"), 200) == %{"status" => "ok"}
  end

  test "GET /ready is 200 when the database answers", %{conn: conn} do
    assert json_response(get(conn, "/ready"), 200)["database"] == "up"
  end
end
```

```elixir
defmodule TicketRush.TelemetryTest do
  use TicketRush.DataCase, async: false

  test "a hold emits [:ticket_rush, :reservation, :hold] with the outcome" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ticket_rush, :reservation, :hold]])
    seat = TicketRush.Fixtures.seat!()
    {:ok, _} = TicketRush.Reservations.hold(seat.id, "u1", idempotency_key: "kt")
    assert_receive {[:ticket_rush, :reservation, :hold], ^ref, %{duration: d}, %{result: :ok}}
    assert d > 0, "duration must be measured"
  end
end
```

**Step 2:** Run → FAIL.

**Step 3: Implement**

`/health` and `/ready` live **outside** the `:api` pipeline (no auth, no rate limit) in their own `scope "/"`. `HealthController.ready/2` runs `Ecto.Adapters.SQL.query(Repo, "SELECT 1")`; `{:ok, _}` → 200 `%{status: "ok", database: "up"}`, otherwise 503 `%{status: "unavailable", database: "down"}`.

In the facade wrap `hold/3` with a span-like measurement:
```elixir
def hold(seat_id, user_id, opts) do
  start = System.monotonic_time()
  result = strategy().hold(seat_id, user_id, opts)
  outcome = case result do {:ok, _} -> :ok; {:replayed, _} -> :replayed; {:error, r} when is_atom(r) -> r; _ -> :error end
  :telemetry.execute([:ticket_rush, :reservation, :hold],
    %{duration: System.monotonic_time() - start}, %{result: outcome, strategy: strategy()})
  # broadcast on {:ok, _} exactly as in Task 8
  result
end
```
`api/lib/ticket_rush/telemetry_logger.ex` (call `TicketRush.TelemetryLogger.attach()` as the first line of `Application.start/2`):

```elixir
defmodule TicketRush.TelemetryLogger do
  require Logger
  @handler_id "ticket-rush-hold-logger"

  def attach do
    # A remote capture (&Mod.fun/4) keeps the handler fast and survives code reloads.
    :telemetry.attach(@handler_id, [:ticket_rush, :reservation, :hold], &__MODULE__.handle_event/4, nil)
  end

  def handle_event(_event, %{duration: duration}, %{result: result, strategy: strategy}, _config) do
    Logger.info("reservation_hold",
      result: result,
      strategy: inspect(strategy),
      duration_us: System.convert_time_unit(duration, :native, :microsecond)
    )
  end
end
```

In `config/prod.exs`: `config :logger, :default_handler, formatter: {LoggerJSON.Formatters.Basic, metadata: :all}`. Study note for `docs/notes/phase9.md`: why `:telemetry.execute` costs almost nothing when no handler is attached (it is an ETS lookup that returns an empty list).

**Step 4:** Run `make test` → `0 failures`.

**Step 5: Commit** — `git add -A && git commit -m "feat: add health checks, telemetry and json logs"`

### Task 17: Production release (mix release, multi-stage Docker)

**Files:**
- Create: `api/Dockerfile` (generated), `api/lib/ticket_rush/release.ex` (generated), `api/rel/overlays/bin/migrate` (generated)
- Modify: `api/config/runtime.exs`, `.gitignore`

**Step 1: Generate** — Run:
```bash
docker compose run --rm api mix phx.gen.release --docker
```
Expected: creates `Dockerfile`, `.dockerignore`, `lib/ticket_rush/release.ex`, `rel/overlays/bin/{server,migrate}`. Read each generated file and write a one-line note per file in `docs/notes/phase9.md` (what `Release.migrate/0` does, why releases need `runtime.exs` for config).

**Step 2: Configure runtime** — replace the generated `if config_env() == :prod do ... end` block in `api/config/runtime.exs` and add the two settings after it:

```elixir
if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is missing"
  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE is missing"
  host = System.get_env("PHX_HOST") || raise "PHX_HOST is missing"

  config :ticket_rush, TicketRush.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    # Fly's private network is IPv6-only.
    socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])

  config :ticket_rush, TicketRushWeb.Endpoint,
    # TLS terminates at the platform proxy; the app only needs to know its public URL.
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base
end

# Applies in every environment; defaults keep dev and test unchanged.
config :ticket_rush, :reservation_strategy,
  (case System.get_env("RESERVATION_STRATEGY", "postgres") do
     "otp" -> TicketRush.Reservations.Otp
     _ -> TicketRush.Reservations.Postgres
   end)

if rate_limit = System.get_env("RATE_LIMIT"),
  do: config(:ticket_rush, :rate_limit, String.to_integer(rate_limit))
```
Keep `PHX_SERVER`/`server: true` handling that the generator already emitted (the `bin/server` script sets it). Oban's `queues: [holds: 20]` stays in `config/config.exs` from Task 9. If Task 12 already added a strategy block to `runtime.exs`, delete that earlier copy: the block above replaces it.

**Step 3: Build and run the real release locally**

```bash
docker build -t ticket-rush:local api
docker run --rm -d --name tr-prod --network ticket-rush_default -p 4001:4000 \
  -e DATABASE_URL=ecto://postgres:postgres@db/ticket_rush_prod \
  -e SECRET_KEY_BASE=$(openssl rand -base64 48) -e PHX_HOST=localhost ticket-rush:local
docker exec tr-prod /app/bin/migrate && curl -s localhost:4001/ready
```
Expected: `{"status":"ok","database":"up"}`. (Create `ticket_rush_prod` first with `docker compose exec db createdb -U postgres ticket_rush_prod`; stop with `docker stop tr-prod`.)

**Step 4: Commit** — `git add -A && git commit -m "build: add production release and docker image"`

---

## Phase 10 — Web front-end (React + TypeScript)

> **TypeScript Refresher: type system and the event loop in the browser.**
> Types are erased at runtime, so data crossing a boundary (HTTP, WebSocket) must be validated at runtime: `z.infer<typeof schema>` derives the static type from the validator so both stay in sync. Discriminated unions model "one of several shapes" and `switch` exhaustiveness (`never`) makes adding a case a compile error. Generics keep helpers reusable without `any` (`function request<S extends z.ZodTypeAny>(schema: S): Promise<z.infer<S>>`). `async/await` yields to the event loop, so a long computation freezes the UI while pending network calls do not.

### Task 18: Web app skeleton and typed API client

**Files:**
- Create: `web/package.json`, `tsconfig.json`, `vite.config.ts`, `index.html`, `src/main.tsx`, `src/api/schemas.ts`, `src/api/client.ts`, `src/api/result.ts`
- Test: `web/src/api/client.test.ts`, `web/src/api/schemas.test.ts`
- Modify: `docker-compose.yml` (add a `web` service, profile `web`), `.gitignore`

**Step 1:** Add the `web` service to `docker-compose.yml` (next to `bench`) and its volume:

```yaml
  web:
    image: node:22
    working_dir: /web
    volumes: ["./web:/web", "web_modules:/web/node_modules"]
    ports: ["5173:5173"]
    profiles: ["web"]
    command: npm run dev -- --host 0.0.0.0
```
and extend the volumes line to `volumes: { pgdata: {}, api_build: {}, api_deps: {}, bench_modules: {}, web_modules: {} }`. Scaffold the app (the service cannot do it, the folder does not exist yet):

```bash
docker run --rm -v "$PWD":/work -w /work node:22 npm create vite@latest web -- --template react-ts
docker compose run --rm web npm install
docker compose run --rm web npm i zod phoenix
docker compose run --rm web npm i -D vitest @testing-library/react @testing-library/jest-dom jsdom fast-check @types/phoenix
```
Expected: `web/package.json` lists the dependencies and `docker compose run --rm web npx tsc --version` prints a version. In `vite.config.ts` set `server.proxy` for `/api` → `http://api:4000` and `/socket` → `ws://api:4000` (`ws: true`), so there is no CORS in dev or prod. Add `"typecheck": "tsc --noEmit"` and `"test": "vitest run"` scripts.

**Step 2: Failing tests**

```ts
// schemas.test.ts
import { describe, it, expect } from "vitest";
import fc from "fast-check";
import { Credentials, SeatSchema, ReservationSchema } from "./schemas";

describe("schemas", () => {
  it("accepts any well-formed credentials", () => {
    fc.assert(fc.property(fc.emailAddress(), fc.string({ minLength: 8 }), (email, password) =>
      Credentials.safeParse({ email, password }).success));
  });
  it("rejects short passwords", () => {
    expect(Credentials.safeParse({ email: "a@b.co", password: "short" }).success, "8 chars minimum").toBe(false);
  });
  it("only knows the four reservation statuses", () => {
    expect(ReservationSchema.safeParse({ id: 1, seat_id: 1, status: "bogus", expires_at: "2030-01-01T00:00:00Z" }).success).toBe(false);
  });
});
```

```ts
// client.test.ts
import { describe, it, expect, vi } from "vitest";
import { ApiClient } from "./client";

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });
const reservation = { id: 1, seat_id: 7, status: "held", expires_at: "2030-01-01T00:00:00Z" };

describe("ApiClient.hold", () => {
  it("returns ok on 201 and sends the bearer token and an idempotency key", async () => {
    const fetchFn = vi.fn().mockResolvedValue(json(201, { data: reservation }));
    const api = new ApiClient("", fetchFn as unknown as typeof fetch, () => "tok");
    const result = await api.hold(1, 7);
    expect(result).toEqual({ ok: true, value: reservation });
    const init = fetchFn.mock.calls[0]![1] as RequestInit;
    expect((init.headers as Record<string, string>)["authorization"]).toBe("Bearer tok");
    expect((init.headers as Record<string, string>)["idempotency-key"], "key must be present").toBeTruthy();
  });

  it.each([[409, "taken"], [410, "expired"], [422, "invalid"], [429, "rate_limited"], [401, "unauthorized"]] as const)(
    "maps %i to %s", async (status, reason) => {
      const api = new ApiClient("", vi.fn().mockResolvedValue(json(status, {})) as unknown as typeof fetch, () => "tok");
      expect(await api.hold(1, 7)).toEqual({ ok: false, reason });
    });

  it("retries a 503 using the same idempotency key", async () => {
    const fetchFn = vi.fn()
      .mockResolvedValueOnce(json(503, {}))
      .mockResolvedValueOnce(json(201, { data: reservation }));
    const api = new ApiClient("", fetchFn as unknown as typeof fetch, () => "tok", 1);
    expect((await api.hold(1, 7)).ok).toBe(true);
    const keys = fetchFn.mock.calls.map((c) => ((c[1] as RequestInit).headers as Record<string, string>)["idempotency-key"]);
    expect(keys[0], "a retry must reuse the key or it is not idempotent").toBe(keys[1]);
  });
});
```

**Step 3:** Run `docker compose run --rm web npm test` → FAIL. **Step 4: Implement**

`src/api/schemas.ts`:
```ts
import { z } from "zod";
export const Credentials = z.object({ email: z.string().email(), password: z.string().min(8) });
export type Credentials = z.infer<typeof Credentials>;
export const SeatSchema = z.object({ id: z.number(), section: z.string(), row: z.string(), number: z.number(), price_cents: z.number(), taken: z.boolean() });
export type Seat = z.infer<typeof SeatSchema>;
export const ReservationSchema = z.object({
  id: z.number(), seat_id: z.number(),
  status: z.enum(["held", "confirmed", "expired", "cancelled"]), expires_at: z.string(),
});
export type Reservation = z.infer<typeof ReservationSchema>;
```

`src/api/result.ts`:
```ts
export type Failure = "taken" | "expired" | "invalid" | "rate_limited" | "unauthorized" | "unavailable";
export type Result<T, E extends string = Failure> = { ok: true; value: T } | { ok: false; reason: E };
export const ok = <T,>(value: T): Result<T> => ({ ok: true, value });
export const fail = (reason: Failure): Result<never> => ({ ok: false, reason });
export function assertNever(x: never): never { throw new Error(`unhandled: ${JSON.stringify(x)}`); }
```

`src/api/client.ts`:
```ts
import { z } from "zod";
import { ReservationSchema, SeatSchema, type Reservation, type Seat } from "./schemas";
import { fail, ok, type Failure, type Result } from "./result";

const STATUS_TO_FAILURE: Record<number, Failure> = {
  409: "taken", 410: "expired", 422: "invalid", 429: "rate_limited", 401: "unauthorized",
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class ApiClient {
  constructor(
    private readonly baseUrl: string,
    private readonly fetchFn: typeof fetch,
    private readonly getToken: () => string | null,
    private readonly baseDelayMs = 100,
    private readonly maxRetries = 3,
  ) {}

  /** Generic, validated request: the return type is inferred from the schema. */
  private async send<S extends z.ZodTypeAny>(path: string, schema: S, init: RequestInit) {
    const res = await this.fetchFn(`${this.baseUrl}${path}`, {
      ...init, signal: AbortSignal.timeout(5000),
      headers: { "content-type": "application/json", authorization: `Bearer ${this.getToken() ?? ""}`, ...(init.headers as object) },
    });
    const body: unknown = await res.json().catch(() => ({}));
    return { status: res.status, data: res.ok ? (schema.parse(body) as z.infer<S>) : undefined };
  }

  async seats(eventId: number): Promise<Seat[]> {
    const r = await this.send(`/api/v1/events/${eventId}/seats`, z.object({ data: z.array(SeatSchema) }), { method: "GET" });
    return r.data?.data ?? [];
  }

  async hold(eventId: number, seatId: number): Promise<Result<Reservation>> {
    const key = crypto.randomUUID();           // one key per user intent, reused by every retry
    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      try {
        const r = await this.send(`/api/v1/events/${eventId}/reservations`, z.object({ data: ReservationSchema }), {
          method: "POST", headers: { "idempotency-key": key }, body: JSON.stringify({ seat_id: seatId }),
        });
        if (r.status === 200 || r.status === 201) return ok(r.data!.data);
        const failure = STATUS_TO_FAILURE[r.status];
        if (failure) return fail(failure);
        await sleep(this.baseDelayMs * 2 ** attempt);   // 503 / unexpected: back off
      } catch {
        await sleep(this.baseDelayMs * 2 ** attempt);   // timeout / network
      }
    }
    return fail("unavailable");
  }
}
```

**Step 5:** Run `docker compose run --rm web npm test && docker compose run --rm web npm run typecheck` → all pass, no type errors.

**Step 6: Commit** — `git add -A && git commit -m "feat: add web app skeleton and typed api client"`

### Task 19: Live seat map (Channels) and login

**Files:**
- Create: `web/src/hooks/useEventSeats.ts`, `web/src/components/SeatMap.tsx`, `web/src/components/LoginForm.tsx`, `web/src/state/seatReducer.ts`
- Modify: `web/src/App.tsx`
- Test: `web/src/state/seatReducer.test.ts`, `web/src/components/SeatMap.test.tsx`

**Step 1: Failing tests**

```ts
// seatReducer.test.ts
import { describe, it, expect } from "vitest";
import fc from "fast-check";
import { seatReducer, type SeatState, type SeatEvent } from "./seatReducer";

const seat = (id: number) => ({ id, section: "A", row: "1", number: id, price_cents: 1000, taken: false });
const initial = (ids: number[]): SeatState => ({ seats: ids.map(seat), unavailable: new Set<number>() });

describe("seatReducer", () => {
  it("marks a seat unavailable on seat_held and available again on seat_released", () => {
    const held = seatReducer(initial([1, 2]), { type: "seat_held", seatId: 1 });
    expect(held.unavailable.has(1), "seat 1 must be unavailable").toBe(true);
    const released = seatReducer(held, { type: "seat_released", seatId: 1 });
    expect(released.unavailable.has(1)).toBe(false);
  });

  it("applying the same event twice equals applying it once (idempotent)", () => {
    const events = fc.constantFrom<SeatEvent["type"]>("seat_held", "seat_released", "seat_sold");
    fc.assert(fc.property(events, fc.integer({ min: 1, max: 5 }), (type, seatId) => {
      const ev = { type, seatId } as SeatEvent;
      const once = seatReducer(initial([1, 2, 3, 4, 5]), ev);
      const twice = seatReducer(once, ev);
      expect([...twice.unavailable].sort()).toEqual([...once.unavailable].sort());
    }));
  });

  it("never mutates the previous state", () => {
    const start = initial([1, 2]);
    seatReducer(start, { type: "seat_held", seatId: 1 });
    expect(start.unavailable.size, "the input state must stay untouched").toBe(0);
  });
});
```

```tsx
// SeatMap.test.tsx
import { render, screen, fireEvent } from "@testing-library/react";
import { describe, it, expect, vi } from "vitest";
import { SeatMap } from "./SeatMap";

const seats = [1, 2].map((id) => ({ id, section: "A", row: "1", number: id, price_cents: 1000, taken: false }));

describe("SeatMap", () => {
  it("disables unavailable seats and reports a click on a free one", () => {
    const onHold = vi.fn();
    render(<SeatMap seats={seats} unavailable={new Set([2])} onHold={onHold} />);
    expect((screen.getByRole("button", { name: /A-1-2/ }) as HTMLButtonElement).disabled, "taken seat must be disabled").toBe(true);
    fireEvent.click(screen.getByRole("button", { name: /A-1-1/ }));
    expect(onHold).toHaveBeenCalledWith(1);
  });
});
```

**Step 2:** Run → FAIL. **Step 3: Implement**

```ts
// seatReducer.ts
import type { Seat } from "../api/schemas";
export type SeatState = { seats: Seat[]; unavailable: Set<number> };
export type SeatEvent =
  | { type: "loaded"; seats: Seat[] }
  | { type: "seat_held" | "seat_sold" | "seat_released"; seatId: number };

export function seatReducer(state: SeatState, ev: SeatEvent): SeatState {
  switch (ev.type) {
    case "loaded": return { seats: ev.seats, unavailable: new Set(ev.seats.filter((s) => s.taken).map((s) => s.id)) };
    case "seat_held":
    case "seat_sold": return { ...state, unavailable: new Set(state.unavailable).add(ev.seatId) };
    case "seat_released": {
      const next = new Set(state.unavailable); next.delete(ev.seatId);
      return { ...state, unavailable: next };
    }
    default: { const _exhaustive: never = ev; return _exhaustive; }
  }
}
```

`SeatMap.tsx` renders one `<button>` per seat with `aria-label={`${s.section}-${s.row}-${s.number}`}`, `disabled={unavailable.has(s.id)}` and `onClick={() => onHold(s.id)}`.

`web/src/hooks/useEventSeats.ts`:

```ts
import { useEffect, useReducer } from "react";
import { Socket } from "phoenix";
import { seatReducer, type SeatState } from "../state/seatReducer";
import type { ApiClient } from "../api/client";

const empty: SeatState = { seats: [], unavailable: new Set() };
type LiveEvent = "seat_held" | "seat_released" | "seat_sold";

export function useEventSeats(eventId: number, token: string, api: ApiClient): SeatState {
  const [state, dispatch] = useReducer(seatReducer, empty);

  useEffect(() => {
    let cancelled = false;
    const socket = new Socket("/socket", { params: { token } });
    socket.connect();
    const channel = socket.channel(`event:${eventId}`);

    const listen = (type: LiveEvent) =>
      channel.on(type, (payload: { seat_id: number }) => dispatch({ type, seatId: payload.seat_id }));
    (["seat_held", "seat_released", "seat_sold"] as const).forEach(listen);

    // Join first, then load the snapshot: events that happen during the fetch are not lost.
    channel.join().receive("ok", () => {
      api.seats(eventId).then((seats) => { if (!cancelled) dispatch({ type: "loaded", seats }); });
    });

    return () => { cancelled = true; channel.leave(); socket.disconnect(); };
  }, [eventId, token, api]);

  return state;
}
```
Known limitation to record in `docs/notes/phase10.md`: a live event received *before* the snapshot lands is overwritten by the snapshot's view of that seat; acceptable here because the snapshot is taken after the join and the next event for that seat corrects it. `LoginForm` validates with `Credentials.safeParse`, calls `POST /api/v1/sessions`, stores the token in memory (state in `App`, **not** `localStorage`; note the XSS trade-off in `docs/notes/phase10.md`). `App` shows the form, then the map; a click calls `api.hold` and displays the `Result` with an exhaustive `switch` over `reason`.

Backend follow-up in the same commit (the seat and event endpoints already exist from Task 7): the UI needs `seat_sold` and manual `seat_released` events. Test first, added to `event_channel_test.exs`:

```elixir
test "confirm pushes seat_sold and release pushes seat_released" do
  seat = TicketRush.Fixtures.seat!()
  {:ok, _, _} = TicketRushWeb.UserSocket |> socket("u", %{current_user_id: 1}) |> subscribe_and_join(TicketRushWeb.EventChannel, "event:#{seat.event_id}")
  {:ok, res} = TicketRush.Reservations.hold(seat.id, "1", idempotency_key: "ks")
  {:ok, _} = TicketRush.Reservations.confirm(res.id, "1")
  assert_push "seat_sold", %{seat_id: sid}, 500
  assert sid == seat.id, "confirm must announce the sale"
end
```
Then in `api/lib/ticket_rush/reservations.ex` add:

```elixir
def confirm(reservation_id, user_id) do
  with {:ok, res} <- strategy().confirm(reservation_id, user_id) do
    broadcast(res.seat_id, "seat_sold")
    {:ok, res}
  end
end

def release(reservation_id) do
  with {:ok, res} <- strategy().release(reservation_id) do
    broadcast(res.seat_id, "seat_released")
    {:ok, res}
  end
end

defp broadcast(seat_id, event) do
  seat = TicketRush.Repo.get!(TicketRush.Events.Seat, seat_id)
  TicketRushWeb.Endpoint.broadcast("event:#{seat.event_id}", event, %{seat_id: seat_id})
end
```
(and reuse `broadcast/2` inside `hold/3` instead of the inline code from Task 8, so there is one broadcast helper.) Run `make test` → `0 failures`.

**Step 4:** Run `docker compose run --rm web npm test && npm run typecheck` and `make test` → all pass.

**Step 5: Manual check** — `docker compose up -d db api && docker compose --profile web up web`, open `http://localhost:5173` in two browsers, log in as two users, hold a seat in one and confirm it greys out in the other without a refresh. Record a screenshot path or a short note in `docs/notes/phase10.md`.

**Step 6: Commit** — `git add -A && git commit -m "feat: add live seat map and login to web app"`

---

## Phase 11 — CI/CD and deployment (Fly.io)

> **DevOps Refresher.** CI proves every change builds and passes tests in a clean environment; CD ships only commits that passed CI. A release image is built once and promoted, never rebuilt per environment. Secrets live in the platform (`fly secrets`, GitHub Actions secrets), never in the repo. Migrations run as a `release_command` *before* traffic moves to the new version, so a bad migration blocks the deploy instead of breaking production.

### Task 20: Continuous integration (GitHub Actions)

**Files:**
- Create: `.github/workflows/ci.yml`

**Step 1: Write the workflow**

```yaml
name: ci
on:
  push: { branches: [main] }
  pull_request:

jobs:
  api:
    runs-on: ubuntu-latest
    services:
      db:
        image: postgres:17
        env: { POSTGRES_USER: postgres, POSTGRES_PASSWORD: postgres }
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready -U postgres" --health-interval 5s --health-timeout 5s --health-retries 10
    env: { MIX_ENV: test, DATABASE_HOST: localhost }
    defaults: { run: { working-directory: api } }
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: { elixir-version: "1.18", otp-version: "27" }
      - uses: actions/cache@v4
        with:
          path: |
            api/deps
            api/_build
          key: mix-${{ runner.os }}-${{ hashFiles('api/mix.lock') }}
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix compile --warnings-as-errors
      - run: mix test

  web:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: web } }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: npm, cache-dependency-path: web/package-lock.json }
      - run: npm ci
      - run: npm run typecheck
      - run: npm test
      - run: npm run build

  bench:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: bench } }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: npm, cache-dependency-path: bench/package-lock.json }
      - run: npm ci
      - run: npx tsc --noEmit
```

**Step 2: Validate locally before pushing** — Run: `mix format --check-formatted` and `mix compile --warnings-as-errors` through compose (`docker compose run --rm -e MIX_ENV=test api sh -c "mix format --check-formatted && mix compile --warnings-as-errors"`). Expected: no output, exit 0. Fix formatting with `mix format` and commit it separately.

**Step 3: Push on a branch and open a PR** (`git switch -c ci/add-workflow && git push -u origin ci/add-workflow`), then check the run in the GitHub Actions tab (or with the `gh` CLI if it is authenticated for github.com). Expected: three green jobs (`api`, `web`, `bench`); the `image` job joins in Task 21. 🛑 If a job fails, show the failing log excerpt to the owner before fixing.

**Step 4: Enable branch protection** — owner action in GitHub → Settings → Branches: require the `api`, `web` and `bench` checks on `main`. (Needs repository admin rights; an agent usually cannot do this.)

**Step 5: Commit** — `git add .github && git commit -m "ci: add github actions workflow"`

### Task 21: Single deployable (serve the web build from Phoenix)

**Files:**
- Modify: `api/Dockerfile` (moved to the repo root as `Dockerfile` so the build context contains `web/` and `api/`), `.dockerignore`, `api/lib/ticket_rush_web/endpoint.ex`, `api/lib/ticket_rush_web/router.ex`, `docker build` commands from Task 17
- Test: `api/test/ticket_rush_web/controllers/page_controller_test.exs`

**Step 1: Failing test**

```elixir
test "GET / serves the SPA index and unknown client routes fall back to it", %{conn: conn} do
  File.mkdir_p!("priv/static")
  File.write!("priv/static/index.html", "<div id=root></div>")
  assert html_response(get(conn, "/"), 200) =~ "id=root"
  assert html_response(get(conn, "/events/1"), 200) =~ "id=root", "deep links must reach the SPA"
  assert json_response(get(conn, "/api/v1/nope"), 404), "API 404s must stay JSON"
end
```

**Step 2:** Run → FAIL.

**Step 3: Implement** — In `Plug.Static` (`endpoint.ex`) serve `priv/static` at `/` (`only: ~w(assets index.html favicon.ico)`). Add a final catch-all `get "/*path", PageController, :index` **after** every `/api`, `/health`, `/ready` scope; `PageController.index/2` sends `priv/static/index.html` (`send_file(conn, 200, Application.app_dir(:ticket_rush, "priv/static/index.html"))`). Replace the generated Elixir Dockerfile with a root-level, three-stage one (the build context must contain both `web/` and `api/`). The generator's `api/Dockerfile` is only a reference from Task 17: delete it (`git rm api/Dockerfile`) once the new one builds. Both Elixir stages use the same base image so the release and its runtime libraries always match:

```dockerfile
# --- Stage 1: build the SPA
FROM node:22 AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# --- Stage 2: compile the release
FROM elixir:1.18-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY api/mix.exs api/mix.lock ./
RUN mix deps.get --only prod
COPY api/config config
RUN mix deps.compile
COPY api/lib lib
COPY api/priv priv
COPY api/rel rel
COPY --from=web /web/dist priv/static
RUN mix compile && mix release

# --- Stage 3: runtime
FROM elixir:1.18-slim AS runtime
WORKDIR /app
RUN useradd --create-home app
COPY --from=build --chown=app:app /app/_build/prod/rel/ticket_rush ./
USER app
ENV PHX_SERVER=true
EXPOSE 4000
CMD ["/app/bin/server"]
```
`.dockerignore` (repo root):
```
.git
**/node_modules
**/_build
**/deps
**/dist
api/Dockerfile.dev
docs
```
(The runtime stage reuses the Elixir image on purpose: simple and safe, at the cost of image size. Shrinking it to `debian:*-slim` is a later optimization, only after checking the libc of both images match.)
Update the context in the local build command to `docker build -t ticket-rush:local -f Dockerfile .`.

**Step 4:** Run `make test` → `0 failures`; rebuild the image and run Task 17's `curl` checks plus `curl -s localhost:4001/ | head -c 200` → shows the SPA HTML.

**Step 5: Smoke script and image check in CI.** Create `scripts/smoke.sh` (`chmod +x`). It needs no seeded data, so it works against an empty production database:

```bash
#!/usr/bin/env bash
# Usage: scripts/smoke.sh <base-url>   e.g. scripts/smoke.sh http://localhost:4001
set -euo pipefail
BASE="${1:?usage: smoke.sh <base-url>}"
json='content-type: application/json'

echo "waiting for /ready"
for i in $(seq 1 20); do
  curl -fsS "$BASE/ready" | grep -q '"database":"up"' && break
  [ "$i" = 20 ] && { echo "FAIL: /ready never became healthy"; exit 1; }
  sleep 3
done

email="smoke-$(date +%s)-$RANDOM@example.com"
curl -fsS -X POST "$BASE/api/v1/users" -H "$json" -d "{\"email\":\"$email\",\"password\":\"correct horse battery\"}" >/dev/null
token=$(curl -fsS -X POST "$BASE/api/v1/sessions" -H "$json" -d "{\"email\":\"$email\",\"password\":\"correct horse battery\"}" \
  | sed -E 's/.*"token":"([^"]+)".*/\1/')
[ -n "$token" ] || { echo "FAIL: no token"; exit 1; }

curl -fsS "$BASE/api/v1/events" >/dev/null
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/events/1/reservations" -H "$json" -d '{"seat_id":1}')
[ "$code" = 401 ] || { echo "FAIL: unauthenticated hold returned $code, expected 401"; exit 1; }
curl -fsS "$BASE/" | grep -q 'id="root"' || { echo "FAIL: SPA not served"; exit 1; }
echo "OK"
```
Run it against the local release from Task 17: `scripts/smoke.sh http://localhost:4001` → last line `OK`.

Add an `image` job to `.github/workflows/ci.yml` so the Docker image itself is verified on every PR:

```yaml
  image:
    runs-on: ubuntu-latest
    needs: [api, web]
    services:
      db:
        image: postgres:17
        env: { POSTGRES_USER: postgres, POSTGRES_PASSWORD: postgres }
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready -U postgres" --health-interval 5s --health-timeout 5s --health-retries 10
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t ticket-rush:ci -f Dockerfile .
      - run: PGPASSWORD=postgres psql -h localhost -U postgres -c 'CREATE DATABASE ticket_rush_ci'
      - run: |
          docker run -d --name app --network host \
            -e DATABASE_URL=ecto://postgres:postgres@localhost/ticket_rush_ci \
            -e SECRET_KEY_BASE=$(openssl rand -base64 48) -e PHX_HOST=localhost -e PORT=4000 ticket-rush:ci
          docker exec app /app/bin/migrate
      - run: scripts/smoke.sh http://localhost:4000
      - if: failure()
        run: docker logs app
```

**Step 6: Commit** — `git add -A && git commit -m "build: serve the web build from the phoenix release and smoke-test the image"`

### Task 22: Continuous deployment to Fly.io

**Files:**
- Create: `fly.toml`, `.github/workflows/deploy.yml`, `docs/deploy.md`

**Step 1: One-time setup — OWNER actions (they need the owner's Fly.io and GitHub accounts and may be blocked in a sandboxed environment)**. Write them in `docs/deploy.md` and ask the owner to run them in their own terminal:

```bash
brew install flyctl && fly auth login
fly launch --no-deploy --copy-config --name ticket-rush-<unique-suffix> --region gru
fly postgres create --name ticket-rush-db --region gru
fly postgres attach ticket-rush-db            # sets DATABASE_URL as a secret
fly secrets set SECRET_KEY_BASE=$(openssl rand -base64 48) PHX_HOST=ticket-rush-<unique-suffix>.fly.dev
fly tokens create deploy -x 999999h           # copy the token
```
Then in GitHub → Settings → Secrets and variables → Actions add `FLY_API_TOKEN`. 🛑 Stop here and wait for the owner to confirm these are done. If the executor is going to run any `fly` command itself, the owner must first make sure the Fly.io domains are reachable from the execution environment.

**Step 2: `fly.toml`**

```toml
app = "ticket-rush-<unique-suffix>"
primary_region = "gru"

[build]
  dockerfile = "Dockerfile"

[deploy]
  release_command = "/app/bin/migrate"
  strategy = "rolling"

[env]
  PORT = "4000"
  RESERVATION_STRATEGY = "otp"
  POOL_SIZE = "10"
  ECTO_IPV6 = "true"

[http_service]
  internal_port = 4000
  force_https = true
  auto_stop_machines = "off"
  min_machines_running = 1

  [[http_service.checks]]
    method = "get"
    path = "/ready"
    interval = "15s"
    timeout = "3s"
    grace_period = "20s"

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
```

Important constraint to document in `docs/deploy.md`: **Strategy A keeps state in memory per node**, so run exactly one machine (`min_machines_running = 1`, no autoscaling out) or switch `RESERVATION_STRATEGY=postgres`, which is safe on any number of machines. This is the real production trade-off between the two strategies; discuss it with the user and record the decision.

**Step 3: `.github/workflows/deploy.yml`**

```yaml
name: deploy
on:
  workflow_run:
    workflows: [ci]
    types: [completed]
    branches: [main]

concurrency: { group: deploy-production, cancel-in-progress: false }

jobs:
  deploy:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { ref: "${{ github.event.workflow_run.head_sha }}" }
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only
        env: { FLY_API_TOKEN: "${{ secrets.FLY_API_TOKEN }}" }
      - name: Smoke test
        run: scripts/smoke.sh "https://${{ vars.APP_HOST }}"
```
(Add the repository variable `APP_HOST` = `ticket-rush-<unique-suffix>.fly.dev` in GitHub → Settings → Variables.)

**Step 4: First deploy and verification** — merge the PR to `main`; watch `ci` then `deploy` in the Actions tab. Expected: both green and `curl https://<app>.fly.dev/ready` → `{"status":"ok","database":"up"}`. Then run the Task 12 benchmark against the deployed host with a **small** `BUYERS` (e.g. 500) to avoid abusing a shared plan, and record the results in `docs/benchmark.md` next to the local ones.

**Step 5: Rollback drill** — `fly releases` then `fly deploy --image <previous image>` (document the exact command output in `docs/deploy.md`).

**Step 6: Commit** — `git add -A && git commit -m "ci: add fly.io continuous deployment"`

---

### Final Phase: Code Review & PR Readiness

**Goal:** Comprehensive review and pre-completion validation before declaring work complete.

**Step 1: Run full code review**

Review the full diff (a second AI agent, a teammate, or a code-review tool): correctness under concurrency, test completeness, layering (controllers never call `Repo`), naming, unnecessary abstractions.

**Step 2: Address review findings with user**

For each finding: present the issue, propose a fix or trade-offs, implement the user's decision.

**Step 3: Pre-completion checklist**

- [ ] `make test` passes with 0 failures (including property tests, ≥25 runs)
- [ ] `mix format --check-formatted` and `mix compile --warnings-as-errors` clean
- [ ] Web: `npm run typecheck`, `npm test` and `npm run build` clean in `web/`; Bench: `npx tsc --noEmit` clean in `bench/`
- [ ] CI is green on `main` and the deploy workflow succeeded; `/ready` answers 200 on the Fly.io host
- [ ] Rate limiting, auth, health checks and telemetry each covered by a test (Tasks 14-16)
- [ ] `docs/deploy.md` documents setup, secrets, the single-machine constraint of Strategy A and the rollback drill
- [ ] Benchmark reports `oversold: 0` for both strategies
- [ ] `docs/notes/phase1..9.md`, `docs/benchmark.md`, `docs/postgres-tuning.md` written, in English
- [ ] `git log --format='%an <%ae>'` shows only `Ramon Bezerra <ramonbezerra90@gmail.com>`
- [ ] `README.md` explains how to run everything with `make` and Docker only
- [ ] No AI plan files or scratch migrations committed

**Step 4: Confirm with user**

"All tasks complete and validated. Ready to open a PR or need adjustments?" Only declare complete when the user confirms.
