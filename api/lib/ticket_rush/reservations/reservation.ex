defmodule TicketRush.Reservations.Reservation do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "reservations" do
    field :user_id, :integer
    field :status, Ecto.Enum, values: [:held, :confirmed, :expired, :cancelled], default: :held
    field :expires_at, :utc_datetime
    field :idempotency_key, :string
    belongs_to :seat, TicketRush.Events.Seat
    timestamps()
  end

  def hold_changeset(res, attrs) do
    res
    |> cast(attrs, [:seat_id, :user_id, :status, :idempotency_key, :expires_at])
    |> validate_required([:seat_id, :user_id, :status, :idempotency_key, :expires_at])
    |> validate_inclusion(:status, [:held])
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> foreign_key_constraint(:seat_id)
    |> unique_constraint(:seat_id, name: :one_active_reservation_per_seat, message: "taken")
    |> unique_constraint(:idempotency_key, name: :reservations_user_idempotency_key_index)
  end
end
