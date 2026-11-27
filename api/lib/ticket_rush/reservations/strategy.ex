defmodule TicketRush.Reservations.Strategy do
  alias TicketRush.Reservations.Reservation

  @type hold_opts :: [idempotency_key: String.t(), ttl_seconds: integer()]

  @callback hold(event_id :: integer(), seat_id :: integer(), user_id :: integer(), hold_opts()) ::
              {:ok, Reservation.t()}
              | {:replayed, Reservation.t()}
              | {:error, :taken | :seat_not_found | :idempotency_conflict | Ecto.Changeset.t()}

  @callback confirm(reservation_id :: integer(), user_id :: integer()) ::
              {:ok, Reservation.t()} | {:error, :not_found | :expired | :not_held}

  @callback release(reservation_id :: integer(), user_id :: integer()) ::
              {:ok, Reservation.t()} | {:error, :not_found | :not_held}
end
