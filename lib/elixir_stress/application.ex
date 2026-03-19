defmodule ElixirStress.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirStress.Telemetry,
      {Plug.Cowboy, scheme: :http, plug: ElixirStress.Router, options: [port: 4001]},
      ElixirStress.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ElixirStress.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
