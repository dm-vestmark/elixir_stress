defmodule ElixirStress.Endpoint do
  use Phoenix.Endpoint, otp_app: :elixir_stress

  socket "/live", Phoenix.LiveView.Socket

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, store: :cookie, key: "_elixir_stress_key", signing_salt: "dashboard_salt"
  plug ElixirStress.DashboardRouter
end
