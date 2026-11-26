defmodule TicketRushWeb.Router do
  use TicketRushWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", TicketRushWeb do
    pipe_through :api
  end
end
