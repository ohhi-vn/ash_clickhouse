# Querying

AshClickhouse supports the standard Ash query API. Most features map directly to
ClickHouse SQL.

## Basic CRUD

```elixir
# Create
{:ok, user} = Ash.create(MyApp.User, %{name: "John", email: "john@example.com"})

# Read
users = Ash.read!(MyApp.User)

# Update
Ash.update!(user, %{name: "Jane"})

# Destroy
Ash.destroy!(user)
```

## Filtering

Full `WHERE` support via `Ash.Query` / action filters:

```elixir
MyApp.User
|> Ash.Query.filter(age > 18 and name == "John")
|> Ash.read!()
```

Boolean expressions, nested expressions, and `changeset_filter` are supported.
Relationship filters (`filter_relationship`, unrelated `exists`,
`aggregate_relationship`) are **not** supported yet.

## Sorting, limit, offset, distinct

```elixir
MyApp.User
|> Ash.Query.sort(age: :desc)
|> Ash.Query.limit(10)
|> Ash.Query.offset(20)
|> Ash.Query.distinct(:name)
|> Ash.read!()
```

Keyset pagination is not supported — use `offset`/`limit`.

## Selecting fields

```elixir
MyApp.User
|> Ash.Query.select([:id, :name])
|> Ash.read!()
```

## Aggregates

Native aggregates: `count`, `sum`, `avg`, `min`, `max`.

```elixir
# Aggregate on a query
MyApp.User
|> Ash.Query.aggregate(:count, :id, :total)
|> Ash.read!()

# Aggregate defined on the resource
Ash.read!(MyApp.User, query: [aggregate: :total_count])
```

`aggregate_filter` and `aggregate_sort` are not supported.

## Bulk create

```elixir
Ash.bulk_create!(
  MyApp.User,
  [%{name: "A"}, %{name: "B"}],
  :create
)
```

Bulk create is implemented as a batched `INSERT` (default batch size 1000,
max 100_000). Per-resource `insert_opts` (e.g. `async_insert: 1`) are applied.

## Update / destroy queries

These map to ClickHouse `ALTER TABLE ... UPDATE` / `DELETE` mutations:

```elixir
MyApp.User
|> Ash.Query.filter(age < 0)
|> Ash.update_query!(set: [age: 0])

MyApp.User
|> Ash.Query.filter(status: "deleted")
|> Ash.destroy_query!()
```

Mutations run asynchronously by default; control this with the resource's
`mutations_sync` option (`1` = wait on current replica, `2` = wait on all
replicas, `nil` = async).

## Calculations

Calculations are computed in memory after fetching rows.

## Streaming

`stream` is supported and yields rows from the result set.

## Multitenancy in queries

See [Multitenancy](multitenancy.md). Tenant is set via
`Ash.Query.set_tenant/2` and applied as a database qualifier or a filter
depending on the strategy.
