# Configuration

AshClickhouse is configured in two places: the **Repo** (connection) and the
**resource** (`clickhouse` DSL block).

## Repo configuration

Defined in `config/config.exs` under your OTP app and Repo module:

```elixir
config :my_app, MyApp.Repo,
  url: "http://localhost:8123",
  username: "default",
  password: "",
  database: "my_app_dev",
  pool_size: 10,
  pool_timeout: 30_000,
  ping_retry: 30_000
```

| Option | Default | Description |
| --- | --- | --- |
| `url` | `"http://localhost:8123"` | ClickHouse HTTP URL |
| `username` | `"default"` | Credentials username |
| `password` | `""` | Credentials password |
| `database` | `nil` | Default database name |
| `pool_size` | `10` | Connection pool size |
| `pool_timeout` | `30_000` | Pool checkout timeout (ms) |
| `ping_retry` | `30_000` | Ping retry interval (ms) |

### Repo API

The `use AshClickhouse.Repo` macro provides these functions:

- `MyApp.Repo.config/0` — full repo config
- `MyApp.Repo.database/0` — configured database
- `MyApp.Repo.connection/0` — connection struct
- `MyApp.Repo.query/3` / `query!/3` — run raw SQL
- `MyApp.Repo.insert_rows/4` — batch insert
- `MyApp.Repo.ping/0` — `true`/`false` readiness check
- `MyApp.Repo.create_database/1` / `drop_database/1`

`config/0` and `query/3` / `query!/3` are `defoverridable`, so you can override
them in your own Repo module if needed.

## Resource configuration

See [Resources](resources.md) for the full `clickhouse` DSL options. The most
important ones for configuration are:

- `repo` — which Repo the resource uses
- `database` — overrides the repo's default database
- `engine`, `order_by`, `partition_by`, `primary_key`, `settings` — table DDL
- `base_filter` — applied to every query (e.g. soft-delete scoping)
- `default_context` — merged into every query/changeset
- `migrate` — whether the resource participates in migrations

## Connection options

The connection wrapper (`AshClickhouse.Connection`) accepts:

| Option | Default | Description |
| --- | --- | --- |
| `name` | — | Register the connection under this name |
| `url` | `"http://localhost:8123"` | ClickHouse HTTP URL |
| `username` / `password` | `"default"` / `""` | Credentials |
| `database` | `nil` | Default database |
| `otp_app` | — | App to read config from (used by Repo) |

The default response format is `JSONCompactEachRow`.
