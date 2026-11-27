defmodule TicketRush.Events.Seat do
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime]

  schema "seats" do
    field :section, :string
    field :row, :string
    field :number, :integer
    field :price_cents, :integer
    belongs_to :event, TicketRush.Events.Event
    timestamps()
  end
end
