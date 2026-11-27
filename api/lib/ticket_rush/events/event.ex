defmodule TicketRush.Events.Event do
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime]

  schema "events" do
    field :name, :string
    field :starts_at, :utc_datetime
    field :status, Ecto.Enum, values: [:draft, :on_sale, :closed], default: :on_sale
    has_many :seats, TicketRush.Events.Seat
    timestamps()
  end
end
