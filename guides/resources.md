# Defining Resources

Resources are defined like any other Ash resource, but use
`AshClickhouse.DataLayer` as the data layer and a `clickhouse` DSL block to
configure the backing table.

## The `clickhouse` block

Import the macro module (and only that module) to use the `clickhouse` block:

```elixir
import AshClickhouse.DataLayer.Dsl.Macros

clickhouse do
  table "users"
  repo MyApp.Repo
  database "my_app_dev"

  base_filter [status: "active"]
  default_context %{tenant: "org_123"}
  description "Application users"

  engine "MergeTree()"
  order_by "id"
  partition_by "toYYYYMM(inserted_at)"
  primary_key [:id]
  settings "index_granularity = 8192"

  migrate true
  insert_opts async_insert: 1, wait_for_async_insert: 1
  mutations_sync 1
end
```

The macro module is intentionally separate from `AshClickhouse.DataLayer.Dsl`
(the runtime getters). Importing the macro module does **not** import the
getters, so a resource can define a local helper named like a DSL key (e.g.
`table/1`) without it being shadowed.

## Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `table` | `String.t()` | derived from resource | Table name in ClickHouse |
| `repo` | `module()` | — | The `AshClickhouse.Repo` module |
| `database` | `String.t()` | repo default | Database to use (overrides repo default) |
| `engine` | `String.t()` | `"MergeTree()"` | ClickHouse table engine |
| `order_by` | `String.t()` | — | `ORDER BY` expression for the engine |
| `partition_by` | `String.t()` | — | `PARTITION BY` expression |
| `primary_key` | `list(atom())` | — | Explicit `PRIMARY KEY` columns |
| `settings` | `String.t()` | — | Engine settings string |
| `base_filter` | `term()` | — | Filter applied to all queries |
| `default_context` | `map()` | — | Context merged into every query/changeset |
| `description` | `String.t()` | — | Human-readable description |
| `migrate` | `boolean()` | `true` | Whether to include in migrations |
| `insert_opts` | `keyword()` | `[]` | Options applied to bulk inserts |
| `mutations_sync` | `nil \| 1 \| 2` | `nil` | Default `mutations_sync` for ALTER mutations |

## Runtime getters

Read the configuration at runtime via `AshClickhouse.DataLayer.Dsl`:

```elixir
AshClickhouse.DataLayer.Dsl.table(MyApp.User)            # => "users"
AshClickhouse.DataLayer.Dsl.repo(MyApp.User)             # => MyApp.Repo
AshClickhouse.DataLayer.Dsl.engine(MyApp.User)          # => "MergeTree()"
AshClickhouse.DataLayer.Dsl.migrate?(MyApp.User)        # => true
AshClickhouse.DataLayer.Dsl.insert_opts(MyApp.User)     # => [async_insert: 1, ...]
AshClickhouse.DataLayer.Dsl.mutations_sync(MyApp.User)  # => 1
```

## Attributes and types

Attributes map to ClickHouse columns. See [Types](types.md) for the full
mapping. Primary keys become part of the table definition:

```elixir
attributes do
  uuid_primary_key :id
  attribute :name, :string
  attribute :age, :integer
  attribute :balance, :decimal
  create_timestamp :inserted_at
end
```

## Actions, aggregates, calculations

Standard Ash actions work as expected:

```elixir
actions do
  defaults [:create, :read, :update, :destroy]
  default_accept :*
end

aggregates do
  count :total_count
  count :adult_count, filter: [age: [gte: 18]]
end
```

Aggregates supported natively: `count`, `sum`, `avg`, `min`, `max`.
Calculations are computed in memory.
