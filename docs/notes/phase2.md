# Phase 2 — Ecto Schemas & Migrations Notes

## Core Postgres Design Notes

### Why `WHERE status = 'held'` keeps `reservations_held_expiry_idx` small
The `reservations` table accumulates historical rows over time (`confirmed`, `expired`, `cancelled`). Only rows currently in `held` state are candidates for Oban's hold-expiration sweep (`WHERE status = 'held' AND expires_at <= now()`). By making `reservations_held_expiry_idx` a partial index on `(expires_at) WHERE status = 'held'`, PostgreSQL indexes only the small active working set of live holds instead of the entire table history. As holds transition to `confirmed`, `expired`, or `cancelled`, they leave this index, keeping index scans fast and buffer-pool footprint low.

### Why `on_delete: :restrict` on `reservations.seat_id`
`seats.event_id` uses `on_delete: :delete_all`, while `reservations.seat_id` uses `on_delete: :restrict`. This guarantees that an event or seat with any reservation history (active or historical) cannot be accidentally wiped by a cascading delete. In production, events are soft-closed (`status = :closed`) rather than hard-deleted, which also avoids sequential FK checks against `reservations` (since the only index on `reservations.seat_id` is the partial `one_active_reservation_per_seat` index, which Postgres cannot use for `ON DELETE RESTRICT` checks across `expired`/`cancelled` rows).

## Alternatives Considered & Trade-offs

1. **Partial unique index on `reservations(seat_id)` vs. lockable `status`/`current_reservation_id` column on `seats`**
   - *Chosen:* Partial unique index `one_active_reservation_per_seat` on `reservations(seat_id) WHERE status IN ('held','confirmed')`.
   - *Trade-off:* Keeps reservation state normalized in one table and lets Strategy B rely on a single atomic `INSERT` conflict check rather than coordinating updates across two tables. The trade-off is that `SELECT ... FOR UPDATE SKIP LOCKED` on `seats` for "best available seat" must still respect `READ COMMITTED` visibility with `NOT EXISTS (...)` against `reservations`, and expiry lag between `expires_at` and Oban updates keeps expired rows blocking until transitioned to `expired`.
2. **`varchar + CHECK` + `Ecto.Enum` vs. native PostgreSQL `CREATE TYPE ... AS ENUM`**
   - *Chosen:* `:string` (`varchar`) columns guarded by Postgres `CHECK` constraints (`events_status_check`, `reservations_status_check`) and mapped to Elixir atoms via `Ecto.Enum`.
   - *Trade-off:* Slightly larger storage per row than a 4-byte Postgres enum OID, but avoids Postgres `ENUM` migration friction (removing/renaming enum values and transaction-block limits on `ALTER TYPE ... ADD VALUE`). Updating a `CHECK` constraint later can be done zero-downtime via `ADD CONSTRAINT ... NOT VALID` + `VALIDATE CONSTRAINT`.
3. **`:utc_datetime` (1-second precision) vs. `:utc_datetime_usec`**
   - *Chosen:* `:utc_datetime` across all schemas and migrations (matching Phoenix's generated `generators: [timestamp_type: :utc_datetime]`).
   - *Trade-off:* Consistent `%DateTime{}` types everywhere (no `:naive_datetime` mix) and cleaner second-granularity timestamps for holds/events; under high throughput, `inserted_at` can have 1-second ties, so cursor pagination must tie-break on `id`.
4. **Composite `unique_index(:seats, [:event_id, :section, :row, :number])` vs. separate `index(:seats, [:event_id])`**
   - *Chosen:* Composite unique index only.
   - *Trade-off:* PostgreSQL uses the leftmost prefix (`event_id`) for `WHERE event_id = $1` lookups and seat-map ordering, avoiding extra write amplification and memory overhead during bulk seat seeding. Revisit only if Phase 8 `EXPLAIN ANALYZE` shows a regression.
5. **Per-user `[:user_id, :idempotency_key]` uniqueness vs. global `[:idempotency_key]`**
   - *Chosen:* Composite `unique_index(:reservations, [:user_id, :idempotency_key], name: :reservations_user_idempotency_key_index)`.
   - *Trade-off:* Slightly wider index entry, but isolates client-supplied `Idempotency-Key` headers per user so two users sending the same key can never collide or observe each other's reservation on replay.

## Scaling Limits & Downstream Contracts

- **HOT update suppression on `reservations`:** Both `one_active_reservation_per_seat` and `reservations_held_expiry_idx` reference the mutable `status` column. Every lifecycle transition (`held -> confirmed | expired | cancelled`) therefore disables PostgreSQL HOT (Heap-Only Tuple) updates, increasing dead-tuple churn under heavy contention. Phase 8 will tune `fillfactor` and per-table `autovacuum` settings on `reservations`.
- **Forward contracts (Phases 3–9):** See *Active Schema Contracts (Phases 3–9)* in `docs/plans/2026-11-25-ticket-rush-implementation-plan.md` for the authoritative rules on `Ecto.Enum` atoms, `:bigint` `user_id` + Phase 9 `NOT VALID` FK rollout, dual-unique-index conflict handling, and atomic `confirm`/expiry SQL guards.
