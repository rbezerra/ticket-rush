defmodule TicketRush.Repo do
  use Ecto.Repo,
    otp_app: :ticket_rush,
    adapter: Ecto.Adapters.Postgres
end
