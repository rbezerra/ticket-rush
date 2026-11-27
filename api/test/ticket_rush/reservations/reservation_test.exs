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

    refute cs.valid?,
           "idempotency_key over 255 chars must fail validation instead of raising a Postgres truncation error"

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

    assert {:error, failed_cs} =
             %Reservation{} |> Reservation.hold_changeset(dup_attrs) |> Repo.insert()

    assert %{seat_id: ["taken"]} = errors_on(failed_cs)
  end

  test "hold_changeset maps duplicate (user_id, idempotency_key) to a changeset error" do
    [seat1, seat2] = Fixtures.seats!(2)

    attrs1 = %{
      seat_id: seat1.id,
      user_id: 1,
      idempotency_key: "dup-key",
      expires_at: future_expiry()
    }

    assert {:ok, _} = %Reservation{} |> Reservation.hold_changeset(attrs1) |> Repo.insert()

    attrs2 = %{
      seat_id: seat2.id,
      user_id: 1,
      idempotency_key: "dup-key",
      expires_at: future_expiry()
    }

    assert {:error, failed_cs} =
             %Reservation{} |> Reservation.hold_changeset(attrs2) |> Repo.insert()

    assert %{idempotency_key: ["has already been taken"]} = errors_on(failed_cs)
  end
end
