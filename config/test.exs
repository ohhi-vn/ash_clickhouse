import Config

# Default test configuration. Integration tests override the repo URL at runtime
# when connecting to a test container or a directly-provided ClickHouse instance
# (see CLICKHOUSE_DIRECT / CLICKHOUSE_URL env vars).
config :ash_clickhouse, AshClickhouse.TestRepo,
  url: "http://localhost:8123",
  username: "default",
  password: "",
  database: nil
