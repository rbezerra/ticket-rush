defmodule TicketRush.Fixtures do
  alias TicketRush.{Repo, Events.Event, Events.Seat}

  def event!(attrs \\ %{}) do
    defaults = %{name: "Show", starts_at: ~U[2030-01-01 20:00:00Z]}

    attrs =
      case Map.get(attrs, :starts_at) do
        %DateTime{} = dt -> Map.put(attrs, :starts_at, DateTime.truncate(dt, :second))
        _ -> attrs
      end

    Repo.insert!(struct!(Event, Map.merge(defaults, attrs)))
  end

  @doc "Inserts `n` seats for one event and returns them."
  def seats!(n, event \\ nil) do
    event = event || event!()

    for i <- 1..n//1 do
      Repo.insert!(%Seat{event_id: event.id, section: "A", row: "1", number: i, price_cents: 1000})
    end
  end

  def seat!, do: hd(seats!(1))
end
