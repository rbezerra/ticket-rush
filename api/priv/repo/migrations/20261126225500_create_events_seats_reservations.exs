defmodule TicketRush.Repo.Migrations.CreateEventsSeatsReservations do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :name, :string, null: false
      add :starts_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "on_sale"
      timestamps(type: :utc_datetime)
    end

    create constraint(:events, :events_status_check,
             check: "status IN ('draft', 'on_sale', 'closed')"
           )

    create table(:seats) do
      add :event_id, references(:events, on_delete: :delete_all), null: false
      add :section, :string, null: false
      add :row, :string, null: false
      add :number, :integer, null: false
      add :price_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:seats, [:event_id, :section, :row, :number])
    create constraint(:seats, :seats_price_non_negative, check: "price_cents >= 0")
    create constraint(:seats, :seats_number_positive, check: "number > 0")

    create table(:reservations) do
      add :seat_id, references(:seats, on_delete: :restrict), null: false
      add :user_id, :bigint, null: false
      add :status, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :idempotency_key, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create constraint(:reservations, :reservations_status_check,
             check: "status IN ('held', 'confirmed', 'expired', 'cancelled')"
           )

    create unique_index(:reservations, [:user_id, :idempotency_key],
             name: :reservations_user_idempotency_key_index
           )

    create unique_index(:reservations, [:seat_id],
             where: "status IN ('held','confirmed')",
             name: :one_active_reservation_per_seat
           )

    create index(:reservations, [:expires_at],
             where: "status = 'held'",
             name: :reservations_held_expiry_idx
           )
  end
end
