# TicketRush API

Elixir/Phoenix API for `ticket-rush`.

This project runs **entirely inside Docker** — do not run `mix` directly on the host. Run all commands from the **repository root** (see the root [`README.md`](../README.md) for the full step-by-step guide):

1. Start PostgreSQL:
   ```bash
   docker compose up -d db
   ```
2. Build the `api` image:
   ```bash
   docker compose build api
   ```
3. Install dependencies and set up the database:
   ```bash
   docker compose run --rm api mix setup
   ```
4. Start the Phoenix server (available at [`http://localhost:4000`](http://localhost:4000)):
   ```bash
   docker compose up api
   ```
5. Run the test suite:
   ```bash
   docker compose run --rm -e MIX_ENV=test api mix test
   ```
6. Open an IEx shell with the app loaded:
   ```bash
   docker compose run --rm api iex -S mix
   ```
