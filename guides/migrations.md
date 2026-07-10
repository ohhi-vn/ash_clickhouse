# Migrations

AshClickhouse generates ClickHouse DDL directly from your Ash resources. There
is no separate migration DSL — the table schema is derived from the resource's
attributes and `clickhouse` DSL options.

## Tasks

Two Mix tasks are provided:

```sh
mix ash_clickhouse.setup    # CREATE DATABASE IF NOT EXISTS for each repo
mix ash_clickhouse.migrate  # CREATE TABLE (+ ALTER) for each resource
```

`mix ash_clickhouse.setup` iterates over all `AshClickhouse.Repo` modules and
calls `create_database/0`.

`mix ash_clickhouse.migrate` iterates over all resources that export
`__ash_clickhouse__/1`, filters by `migrate?/1` and matching `repo/1`, then:

1. Runs `Migration.generate_resource_cql/1` (`CREATE TABLE IF NOT EXISTS`)
2. Runs `Migration.alter_table_cql/2` (schema evolution for existing tables)

Resources with `migrate false` are skipped.

## Generated `CREATE TABLE`

`AshClickhouse.Migration.create_table_cql/1` produces a statement like:

```sql
CREATE TABLE IF NOT EXISTS "my_app_dev"."users" (
  "id" UUID,
  "name" String,
  "email" String,
  "age" Int64,
  "inserted_at" DateTime64(6)
)
ENGINE = MergeTree()
ORDER BY (id)
```

The generated clauses are:

- `ENGINE = <engine>` (default `MergeTree()`)
- `PARTITION BY <partition_by>` (if set)
- `ORDER BY (<order_by>)` (required for most engines)
- `PRIMARY KEY (<primary_key>)` (if set)
- `SETTINGS <settings>` (if set)

The database is qualified only when a `database` is configured on the resource
or repo.

## Schema evolution

Because ClickHouse does not support transactional migrations the way
relational databases do, `alter_table_cql/2` emits `ALTER TABLE` statements to
add new columns when the resource definition changes. Run `mix ash_clickhouse.migrate`
again after changing attributes to apply the diff.

## Type mapping

Column types are derived from Ash attribute types. See [Types](types.md) for
the complete table.

## Tips

- Always set `order_by` — most ClickHouse engines require it.
- Use `partition_by` (e.g. `toYYYYMM(inserted_at)`) for large time-series
  tables to improve pruning.
- Keep `migrate false` on resources you manage outside AshClickhouse.
