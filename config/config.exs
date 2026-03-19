import Config

config :elixir_stress, ElixirStress.Endpoint,
  url: [host: "localhost"],
  http: [port: 4002],
  server: true,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "dashboard_live"],
  check_origin: false

config :phoenix, :json_library, Jason
