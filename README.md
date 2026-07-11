# AshClickhouse

> **Note:** This library is under active development, unstable and the API may change.

An [Ash Framework](https://ash-hq.org) data layer for [ClickHouse](https://clickhouse.com). It implements the
`Ash.DataLayer` behaviour using the [`clickhouse`](https://hex.pm/packages/clickhouse) client.

## Features

ClickHouse is a full SQL columnar store, so most Ash query features map directly:

- CRUD (`create`, `read`, `update`, `destroy`)
- `filter`, `sort`, `limit`, `offset`, `select`, `distinct`
- `bulk_create` (batch `INSERT`)
- `update_query` / `destroy_query` (via `ALTER TABLE ... UPDATE/DELETE`)
- Native aggregates (`count`, `sum`, `avg`, `min`, `max`)
- `multitenancy` (database- or attribute-based)
- `calculate`, `composite_primary_key`, `nested_expressions`, `boolean_filter`

### Not supported

- `transact` / `lock` — ClickHouse has no multi-statement transactions
- `keyset` — ClickHouse has no token-based keyset pagination (use `offset`)
- `upsert` — ClickHouse has no `ON CONFLICT` (use `create` + `update_query`)
- `join` — JOINs are not yet implemented
- `combine` (UNION/INTERSECT) — not yet implemented
- `filter_relationship` / `exists` (unrelated) / `aggregate_relationship` — not yet implemented

## Installation

```elixir
def deps do
  [
    {:ash_clickhouse, "~> 0.1.0"}
  ]
end
```

## Quick start

### 1. Configure a Repo

```elixir
defmodule MyApp.Repo do
  use AshClickhouse.Repo, otp_app: :my_app
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  url: "http://localhost:8123",
  database: "my_app_dev"
```

### 2. Add to your supervision tree

```elixir
children = [MyApp.Repo, ...]
```

### 3. Define a resource

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: MyApp.Domain

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table "users"
    repo MyApp.Repo
    engine "MergeTree()"
    order_by "id"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

### 4. Create the database and tables

```sh
mix ash_clickhouse.setup
mix ash_clickhouse.migrate
```

### 5. Use it

```elixir
{:ok, user} = Ash.create(MyApp.User, %{name: "John", email: "john@example.com"})
users = Ash.read!(MyApp.User)
```

## Configuration

### Resource (`clickhouse` DSL)

| Option | Description |
| --- | --- |
| `table` | Table name (overrides default) |
| `repo` | The `AshClickhouse.Repo` module |
| `database` | Database to use (overrides repo default) |
| `engine` | ClickHouse table engine (default `"MergeTree()"`) |
| `order_by` | `ORDER BY` expression for the engine |
| `partition_by` | `PARTITION BY` expression |
| `primary_key` | Explicit primary key columns |
| `settings` | Engine settings string |
| `base_filter` | Filter applied to all queries |
| `default_context` | Context merged into every query/changeset |
| `migrate` | Whether to include in migrations (default `true`) |
| `index` | Declares a data-skipping index (repeatable) |

### Data-skipping indexes

ClickHouse has no B-tree indexes; it uses *data-skipping* indexes (`minmax`,
`set`, `bloom_filter`, `ngrambf_v1`, `tokenbf_v1`) declared in the table DDL.
Declare them inside the `clickhouse` block — the `index` macro may be repeated,
and `granularity` defaults to `1`:

```elixir
clickhouse do
  table "events"
  repo MyApp.Repo
  order_by "id"

  index name: :idx_user_id, expression: "user_id", type: "bloom_filter"
  index name: :idx_created_at, expression: "created_at", type: "minmax", granularity: 4
end
```

Indexes are **additive only**. `mix ash_clickhouse.migrate` emits them in the
`CREATE TABLE` statement for new tables, and issues `ALTER TABLE ... ADD INDEX
IF NOT EXISTS` for existing tables that lack them. Changing an existing index's
`type`/`expression` is **not** auto-applied — `ADD INDEX IF NOT EXISTS` no-ops on
a name collision. The migrate task instead prints a warning (with the exact
`DROP INDEX` + `ADD INDEX` SQL to run) when an existing index's stored
definition differs from the DSL. To change a definition, manually `ALTER TABLE ...
DROP INDEX` and re-run the migration. (A typo in `type` is rejected at compile
time.)

### Repo

| Option | Default |
| --- | --- |
| `url` | `"http://localhost:8123"` |
| `username` | `"default"` |
| `password` | `""` |
| `database` | `nil` |
| `timeout` | `30_000` |

## License

Apache-2.0. See [LICENSE](LICENSE).
