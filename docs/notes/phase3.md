# Phase 3 — Strategy B (Postgres) Notes

## Why Optimistic `INSERT ... ON CONFLICT DO NOTHING RETURNING *`

`reservations` enforces two unique indexes simultaneously:
- `reservations_user_idempotency_key_index` on `(user_id, idempotency_key)`
- `one_active_reservation_per_seat` on `(seat_id) WHERE status IN ('held','confirmed')`

Using `Repo.insert(cs, on_conflict: :nothing, returning: true)` without an explicit conflict target cushions **both** unique indexes without raising a PostgreSQL error or aborting an enclosing transaction (`25P02: current transaction is aborted`). On the happy path, `hold/4` avoids an explicit `BEGIN`/`COMMIT` transaction and avoids a preemptive expiry `UPDATE` before `INSERT`.

**Ecto idiom:** When `on_conflict: :nothing` suppresses an insert, PostgreSQL returns zero rows and Ecto returns `{:ok, %Reservation{id: nil}}` (matching the unsaved changeset struct with `id: nil`). `attempt_hold/5` matches `id: nil` explicitly and delegates to `resolve_conflict/5`, which queries `(user_id, idempotency_key)` to return `{:replayed, existing}` (same `seat_id`), `{:error, :idempotency_conflict}` (different `seat_id`), or falls through to conflict-only lazy expiry.

## Atomic `confirm/2` and `release/2`

Both `confirm/2` and `release/2` invert the naive read-then-write (`Repo.get_by` -> `Repo.update`) into a single atomic `Repo.update_all/3` with `select: r` in the `Ecto.Query` (emitting SQL `RETURNING *`):
- `confirm/2`: `WHERE id = $1 AND user_id = $2 AND status = 'held' AND expires_at > now()`. On `{0, _}`, a diagnostic `Repo.get_by` classifies `:not_found`, `:expired` (matching both lapsed `:held` and already-`:expired` rows so HTTP `410` holds even after Oban/lazy expiry sweeps the row), or `:not_held`.
- `release/2`: `WHERE id = $1 AND user_id = $2 AND status = 'held' AND expires_at > now()`. Requiring `user_id` enforces ownership; the `status == :held` guard blocks cancellation of `:confirmed` reservations, and `expires_at > now()` prevents expired holds from being recorded as `:cancelled` in a race with Oban.

## Strategy Behaviour Boundaries

- `hold/4` takes `event_id` so Strategy A (`EventArbiter`) can route directly through `Registry` without a database lookup, and Strategy B verifies `(event_id, seat_id)` membership (`Repo.exists?`) to prevent cross-event seat spoofing and return `{:error, :seat_not_found}` consistently.
- `release/2` takes `user_id` so ownership enforcement is part of the shared strategy contract ahead of Phase 5/9 HTTP auth.

## Clock-Skew & `SQL.Sandbox` Precision Note

`hold/4` computes `expires_at` from Elixir's `DateTime.utc_now/0` truncated to `:second`, while `confirm/2`, `release/2`, and lazy expiry compare against PostgreSQL `now()` (microsecond precision). If application and database hosts can drift by more than a few seconds, compute `expires_at` inside PostgreSQL via `now() + interval` instead.

In tests under `Ecto.Adapters.SQL.Sandbox`, PostgreSQL `now()` (alias for `transaction_timestamp()`) stays frozen at the sandbox `BEGIN` timestamp for the whole test, so expiry tests use `ttl_seconds: -60` rather than `-1` to avoid wall-clock vs. transaction-start flakes.

## Alternatives Considered & Risks/Limits

1. **Inline lazy expiry on conflict vs. Oban-only expiry:** Chosen: inline lazy expiry only on `hold/4` conflict (retrying `INSERT` once if `expired_count > 0`). If Oban sweeps an expired hold in the microsecond between `INSERT` conflict and `Repo.update_all`, `expired_count` is `0` and the caller receives a transient `{:error, :taken}` — accepted as a rare edge case to avoid adding an extra unconditional `INSERT` on every hot-seat conflict.
2. **Strategy B hot-seat loser amplification:** Under 5k–10k concurrent buyers targeting the same seat, each `:taken` loser executes a seat-membership check plus 3 sequential queries (`INSERT` + `SELECT` + `UPDATE`). This is an expected Strategy B scaling trade-off and a primary comparison point against Strategy A in Phase 7's benchmark.
3. **Non-partial idempotency replay parity:** Because `reservations_user_idempotency_key_index` covers all statuses, replaying an `:expired` or `:cancelled` key still returns `{:replayed, existing}`. Strategy A (Phase 4) must preserve this parity even after `EventArbiter` restarts.
4. **Deferred `SELECT ... FOR UPDATE SKIP LOCKED`:** Mentioned in the design doc for an optional "best available seat" auto-assignment flow; deferred until/unless such an endpoint is added.
