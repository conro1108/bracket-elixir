import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :bracket, BracketWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Wmu5n9D1GhRtv2IfD0dyrfolcDcJ9RwJeRmeU4lFOIVtXxmK47KkRfR3ygJsq1jN",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Short intervals for timer and cleanup tests
config :bracket, :cleanup_interval, 100
config :bracket, :cleanup_inactive_threshold, 200
config :bracket, :host_disconnect_warning_ms, 50
config :bracket, :host_disconnect_transfer_ms, 100
