defmodule TicketRush.Reservations.PostgresTest do
  use TicketRush.ReservationStrategyCase, strategy: TicketRush.Reservations.Postgres

  test "Reservations facade delegates to the default Postgres strategy", %{seat: seat} do
    assert TicketRush.Reservations.strategy() == TicketRush.Reservations.Postgres

    assert {:ok, res} =
             TicketRush.Reservations.hold(seat.event_id, seat.id, 1, idempotency_key: "facade-k1")

    assert {:ok, %{status: :confirmed}} = TicketRush.Reservations.confirm(res.id, 1)
  end
end
