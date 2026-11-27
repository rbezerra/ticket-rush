defmodule TicketRush.SchemaInvariantTest do
  use TicketRush.DataCase, async: true

  setup do
    {:ok, %{rows: [[event_id]]}} =
      Repo.query(
        "INSERT INTO events (name, starts_at, status, inserted_at, updated_at) VALUES ('E', now(), 'on_sale', now(), now()) RETURNING id"
      )

    {:ok, %{rows: [[seat_id]]}} =
      Repo.query(
        "INSERT INTO seats (event_id, section, row, number, price_cents, inserted_at, updated_at) VALUES ($1,'A','1',1,1000, now(), now()) RETURNING id",
        [event_id]
      )

    %{event_id: event_id, seat_id: seat_id}
  end

  defp insert_reservation(seat_id, status, key, user_id) do
    Repo.query(
      "INSERT INTO reservations (seat_id, user_id, status, expires_at, idempotency_key, inserted_at, updated_at) VALUES ($1,$2,$3, now() + interval '5 min', $4, now(), now())",
      [seat_id, user_id, status, key]
    )
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

    assert {:ok, _} = insert_reservation(seat_id, "held", "k2", 2),
           "expired rows must not occupy the seat"
  end

  test "a cancelled reservation does not block a new hold", %{seat_id: seat_id} do
    assert {:ok, _} = insert_reservation(seat_id, "cancelled", "k1", 1)

    assert {:ok, _} = insert_reservation(seat_id, "held", "k2", 2),
           "cancelled rows must not occupy the seat"
  end

  test "database rejects invalid reservation status values", %{seat_id: seat_id} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "reservations_status_check"}}} =
             insert_reservation(seat_id, "invalid", "k1", 1)
  end

  test "database rejects invalid event status values" do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "events_status_check"}}} =
             Repo.query(
               "INSERT INTO events (name, starts_at, status, inserted_at, updated_at) VALUES ('Bad', now(), 'invalid', now(), now())"
             )
  end

  test "database rejects negative seat prices", %{event_id: event_id} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "seats_price_non_negative"}}} =
             Repo.query(
               "INSERT INTO seats (event_id, section, row, number, price_cents, inserted_at, updated_at) VALUES ($1,'A','1',2,-1, now(), now())",
               [event_id]
             )
  end

  test "database rejects non-positive seat numbers", %{event_id: event_id} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "seats_number_positive"}}} =
             Repo.query(
               "INSERT INTO seats (event_id, section, row, number, price_cents, inserted_at, updated_at) VALUES ($1,'A','1',0,1000, now(), now())",
               [event_id]
             )
  end

  test "idempotency key is scoped per user_id", %{seat_id: seat_id} do
    assert {:ok, _} = insert_reservation(seat_id, "expired", "same-key", 1)

    assert {:ok, _} = insert_reservation(seat_id, "held", "same-key", 2),
           "different users must be able to use the same idempotency key"

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "reservations_user_idempotency_key_index"}}} =
             insert_reservation(seat_id, "expired", "same-key", 1)
  end
end
