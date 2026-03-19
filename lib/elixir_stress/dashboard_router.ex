defmodule ElixirStress.DashboardRouter do
  use Phoenix.Router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser
    live_dashboard "/dashboard",
      metrics: ElixirStress.Telemetry,
      request_logger: true
  end
end
