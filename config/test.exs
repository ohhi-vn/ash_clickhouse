import Config

# Register the test domain so Ash doesn't warn that it isn't present in any
# configured domain module. This applies in every Mix environment (including
# `mix compile`, which otherwise sees an empty `ash_domains` and emits warnings
# when the test/support resource modules are compiled).
config :ash_clickhouse, ash_domains: [AshClickhouse.TestDomain]

# Default test configuration. Integration tests override the repo URL at runtime
# when connecting to a test container or a directly-provided ClickHouse instance
# (see CLICKHOUSE_DIRECT / CLICKHOUSE_URL env vars).
config :ash_clickhouse, AshClickhouse.TestRepo,
  url: "http://localhost:8123",
  username: "default",
  password: "",
  database: nil
