defmodule TicketRush.Reservations.Postgres do
  @behaviour TicketRush.Reservations.Strategy

  import Ecto.Query
  alias TicketRush.Events.Seat
  alias TicketRush.Repo
  alias TicketRush.Reservations.Reservation

  @impl true
  def hold(event_id, seat_id, user_id, opts) do
    key = Keyword.get(opts, :idempotency_key)
    ttl = Keyword.get(opts, :ttl_seconds, 300)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      seat_id: seat_id,
      user_id: user_id,
      idempotency_key: key,
      expires_at: DateTime.add(now, ttl, :second)
    }

    cs = Reservation.hold_changeset(%Reservation{}, attrs)

    cond do
      not cs.valid? ->
        {:error, cs}

      not Repo.exists?(from s in Seat, where: s.id == ^seat_id and s.event_id == ^event_id) ->
        {:error, :seat_not_found}

      true ->
        attempt_hold(cs, seat_id, user_id, key, _allow_retry? = true)
    end
  end

  defp attempt_hold(cs, seat_id, user_id, key, allow_retry?) do
    case Repo.insert(cs, on_conflict: :nothing, returning: true) do
      {:ok, %Reservation{id: nil}} ->
        resolve_conflict(cs, seat_id, user_id, key, allow_retry?)

      {:ok, %Reservation{} = res} ->
        {:ok, res}

      {:error, %Ecto.Changeset{} = invalid_cs} ->
        {:error, invalid_cs}
    end
  end

  defp resolve_conflict(cs, seat_id, user_id, key, allow_retry?) do
    case Repo.get_by(Reservation, user_id: user_id, idempotency_key: key) do
      %Reservation{seat_id: ^seat_id} = existing ->
        {:replayed, existing}

      %Reservation{} ->
        {:error, :idempotency_conflict}

      nil when allow_retry? ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {expired_count, _} =
          from(r in Reservation,
            where:
              r.seat_id == ^seat_id and r.status == :held and
                r.expires_at <= fragment("now()")
          )
          |> Repo.update_all(set: [status: :expired, updated_at: now])

        if expired_count > 0 do
          attempt_hold(cs, seat_id, user_id, key, false)
        else
          {:error, :taken}
        end

      nil ->
        {:error, :taken}
    end
  end

  @impl true
  def confirm(id, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(r in Reservation,
        where:
          r.id == ^id and r.user_id == ^user_id and r.status == :held and
            r.expires_at > fragment("now()"),
        select: r
      )

    case Repo.update_all(query, set: [status: :confirmed, updated_at: now]) do
      {1, [res]} ->
        {:ok, res}

      {0, _} ->
        case Repo.get_by(Reservation, id: id, user_id: user_id) do
          nil -> {:error, :not_found}
          %Reservation{status: status} when status in [:held, :expired] -> {:error, :expired}
          %Reservation{} -> {:error, :not_held}
        end
    end
  end

  @impl true
  def release(id, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(r in Reservation,
        where:
          r.id == ^id and r.user_id == ^user_id and r.status == :held and
            r.expires_at > fragment("now()"),
        select: r
      )

    case Repo.update_all(query, set: [status: :cancelled, updated_at: now]) do
      {1, [res]} ->
        {:ok, res}

      {0, _} ->
        case Repo.get_by(Reservation, id: id, user_id: user_id) do
          nil -> {:error, :not_found}
          %Reservation{} -> {:error, :not_held}
        end
    end
  end
end
