defmodule TicketRush.ReservationStrategyCase do
  @moduledoc "Shared contract tests. `use` it with `strategy: Module`."
  defmacro __using__(opts) do
    quote do
      use TicketRush.DataCase, async: false
      alias TicketRush.Fixtures
      @strategy unquote(opts[:strategy])

      setup do: %{seat: Fixtures.seat!()}

      test "hold succeeds on a free seat", %{seat: seat} do
        assert {:ok, res} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1")
        assert res.status == :held, "new reservation must be held"
      end

      test "hold rejects nonexistent seat, event_id/seat_id mismatch, or missing idempotency_key",
           %{seat: seat} do
        other_event = Fixtures.event!()

        assert {:error, %Ecto.Changeset{}} = @strategy.hold(seat.event_id, seat.id, 1, [])

        assert {:error, :seat_not_found} =
                 @strategy.hold(seat.event_id, -1, 1, idempotency_key: "k-missing")

        assert {:error, :seat_not_found} =
                 @strategy.hold(other_event.id, seat.id, 1, idempotency_key: "k-mismatch"),
               "seat belonging to another event must be rejected"
      end

      test "second hold on the same seat is :taken", %{seat: seat} do
        {:ok, _} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1")
        assert {:error, :taken} = @strategy.hold(seat.event_id, seat.id, 2, idempotency_key: "k2")
      end

      test "same idempotency key for same user and seat returns the original reservation", %{
        seat: seat
      } do
        {:ok, a} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1")
        assert {:replayed, b} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1")
        assert a.id == b.id, "replay must not create a second reservation"
      end

      test "replaying an idempotency key after release or expiry still returns {:replayed, existing}",
           %{seat: seat} do
        {:ok, r1} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k-rel")
        {:ok, _} = @strategy.release(r1.id, 1)

        assert {:replayed, %{id: id1, status: :cancelled}} =
                 @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k-rel")

        assert id1 == r1.id

        {:ok, r2} =
          @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k-exp", ttl_seconds: -60)

        {:ok, _} = @strategy.hold(seat.event_id, seat.id, 2, idempotency_key: "k-other")

        assert {:replayed, %{id: id2, status: :expired}} =
                 @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k-exp")

        assert id2 == r2.id
      end

      test "same idempotency key for same user on a different seat is :idempotency_conflict", %{
        seat: seat
      } do
        other_seat = Fixtures.seat!()
        {:ok, _} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1")

        assert {:error, :idempotency_conflict} =
                 @strategy.hold(other_seat.event_id, other_seat.id, 1, idempotency_key: "k1")
      end

      test "idempotency key is isolated per user", %{seat: seat} do
        other_seat = Fixtures.seat!()
        assert {:ok, r1} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "shared-key")

        assert {:ok, r2} =
                 @strategy.hold(other_seat.event_id, other_seat.id, 2,
                   idempotency_key: "shared-key"
                 )

        refute r1.id == r2.id,
               "different users sharing an idempotency key must not replay each other"
      end

      test "an expired hold frees the seat", %{seat: seat} do
        {:ok, _} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1", ttl_seconds: -60)
        assert {:ok, _} = @strategy.hold(seat.event_id, seat.id, 2, idempotency_key: "k2")
      end

      test "confirm moves held to confirmed and handles error states including already-expired rows",
           %{seat: seat} do
        {:ok, r} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1")
        assert {:error, :not_found} = @strategy.confirm(r.id, 2), "wrong user must not confirm"
        assert {:ok, %{status: :confirmed}} = @strategy.confirm(r.id, 1)

        assert {:error, :not_held} = @strategy.confirm(r.id, 1),
               "already confirmed must return :not_held"

        expired_seat = Fixtures.seat!()

        {:ok, r_exp} =
          @strategy.hold(expired_seat.event_id, expired_seat.id, 1,
            idempotency_key: "k-exp",
            ttl_seconds: -60
          )

        assert {:error, :expired} = @strategy.confirm(r_exp.id, 1),
               "lapsed held row must return :expired"

        {:ok, _} =
          @strategy.hold(expired_seat.event_id, expired_seat.id, 2, idempotency_key: "k-sweeper")

        assert {:error, :expired} = @strategy.confirm(r_exp.id, 1),
               "already-expired row must still return :expired"
      end

      test "release cancels a held reservation and rejects confirmed, expired, or unowned reservations",
           %{seat: seat} do
        {:ok, r} = @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "k1")
        assert {:error, :not_found} = @strategy.release(r.id, 2), "wrong user must not release"
        assert {:ok, %{status: :cancelled}} = @strategy.release(r.id, 1)
        assert {:error, :not_held} = @strategy.release(r.id, 1)

        expired_seat = Fixtures.seat!()

        {:ok, r_exp} =
          @strategy.hold(expired_seat.event_id, expired_seat.id, 1,
            idempotency_key: "k-exp-rel",
            ttl_seconds: -60
          )

        assert {:error, :not_held} = @strategy.release(r_exp.id, 1),
               "expired hold must not be marked :cancelled"

        sold_seat = Fixtures.seat!()

        {:ok, r_sold} =
          @strategy.hold(sold_seat.event_id, sold_seat.id, 1, idempotency_key: "k-sold")

        {:ok, _} = @strategy.confirm(r_sold.id, 1)

        assert {:error, :not_held} = @strategy.release(r_sold.id, 1),
               "confirmed reservations must never be cancelled by release"
      end

      test "parallel tasks on the same seat allow only one winner (shared sandbox logical contract)",
           %{seat: seat} do
        results =
          1..2
          |> Task.async_stream(
            fn user_id ->
              @strategy.hold(seat.event_id, seat.id, user_id, idempotency_key: "race-#{user_id}")
            end,
            ordered: false
          )
          |> Enum.map(fn {:ok, res} -> res end)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, :taken}, &1)) == 1
      end

      test "parallel retries with the same (user_id, idempotency_key) return one :ok and one :replayed",
           %{seat: seat} do
        results =
          1..2
          |> Task.async_stream(
            fn _ ->
              @strategy.hold(seat.event_id, seat.id, 1, idempotency_key: "same-race-key")
            end,
            ordered: false
          )
          |> Enum.map(fn {:ok, res} -> res end)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:replayed, _}, &1)) == 1
      end
    end
  end
end
