# Phase 1 — Environment & Phoenix Skeleton Notes

## Generated names (Task 2, Step 5)

Generated with `elixir:1.18` (OTP 28) and `phx_new 1.8.17` (`--no-html --no-assets --no-mailer --no-gettext --no-dashboard --install`).

Command outputs:

- `test/support/*.ex` and `lib/ticket_rush_web.ex` modules:
  - `test/support/conn_case.ex:1`: `defmodule TicketRushWeb.ConnCase` (uses `TicketRushWeb, :verified_routes`)
  - `test/support/data_case.ex:1`: `defmodule TicketRush.DataCase` (defines `errors_on/1` and `setup_sandbox/1`)
  - `lib/ticket_rush_web.ex:1`: `defmodule TicketRushWeb` (defines `:router`, `:channel`, `:controller`, `:verified_routes`)
- `lib/ticket_rush_web/*.ex` usage:
  - `lib/ticket_rush_web/router.ex:2`: `use TicketRushWeb, :router`
- Verified routes (`~p`):
  - `lib/ticket_rush_web.ex:44`: `unquote(verified_routes())` (included in `:controller` and `ConnCase`)
  - `lib/ticket_rush_web.ex:48`: `def verified_routes do` (`use Phoenix.VerifiedRoutes`)
- Key dependencies in `api/mix.exs`:
  - `{:phoenix, "~> 1.8.17"}`
  - `{:phoenix_ecto, "~> 4.5"}`
  - `{:ecto_sql, "~> 3.13"}`
  - `{:bandit, "~> 1.5"}`

Comparison with plan assumptions: **all assumptions hold** (`TicketRush.DataCase` with `errors_on/1`, `TicketRushWeb.ConnCase`, `use TicketRushWeb, :controller` / `:channel`, `~p` verified routes, and Bandit as the HTTP server). No plan snippets need adjustment.

## Supervision tree (Task 2, Step 6)

Root supervisor in `api/lib/ticket_rush/application.ex` (`TicketRush.Supervisor`, strategy `:one_for_one`):

1. `TicketRushWeb.Telemetry` — runs the `:telemetry_poller` and registers VM/Phoenix/Ecto metrics.
2. `TicketRush.Repo` — manages the PostgreSQL connection pool via `DBConnection`.
3. `{DNSCluster, query: ...}` — optional node discovery for clustering (`:ignore` when unconfigured).
4. `{Phoenix.PubSub, name: TicketRush.PubSub}` — local/distributed pub-sub used by Channels and broadcasts.
5. `TicketRushWeb.Endpoint` — starts the Bandit HTTP/WebSocket server and request pipeline.

Study questions:

- **What does `Repo` restart on crash?** Under `strategy: :one_for_one`, if `TicketRush.Repo` crashes, the supervisor restarts **only `TicketRush.Repo`** (its DB connection pool supervisor and pool workers) without restarting `Telemetry`, `PubSub`, or `Endpoint`.
- **Why is `Endpoint` last?** Supervisors start children in list order and shut them down in reverse order. Putting `Endpoint` last ensures `Telemetry`, `Repo`, and `PubSub` are already up before the server starts accepting HTTP/WebSocket traffic, and during shutdown `Endpoint` stops accepting requests first while `Repo` and `PubSub` are still alive to finish in-flight requests.

## Deviations / environment notes

- `mix phx.new .` prompted for confirmation because `api/Dockerfile.dev` already existed; ran non-interactively with `printf 'y\n'`.
- `mix phx.new` initialized a nested `api/.git` repository; removed `api/.git` so `api/` is tracked normally in the parent repo.
- `make` is not installed on the Windows host, so equivalent `docker compose` commands were executed directly.
- Docker Desktop was upgraded from `4.15.0` to `4.100.1` (Docker `29.9.3`) because `4.15.0` was incompatible with WSL 3.0.5 / Linux kernel 6.18 cgroup v2 namespaces.
