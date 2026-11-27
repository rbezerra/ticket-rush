defmodule TicketRush.Reservations do
  @moduledoc "Domain entrypoint delegating reservation operations to the configured strategy."

  def strategy do
    Application.get_env(:ticket_rush, :reservation_strategy, TicketRush.Reservations.Postgres)
  end

  def hold(event_id, seat_id, user_id, opts), do: strategy().hold(event_id, seat_id, user_id, opts)
  def confirm(reservation_id, user_id), do: strategy().confirm(reservation_id, user_id)
  def release(reservation_id, user_id), do: strategy().release(reservation_id, user_id)
end
