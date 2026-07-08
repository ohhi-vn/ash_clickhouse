# Changelog

## 0.1.0

- Initial release of AshClickhouse, an Ash data layer for ClickHouse.
- Implements `Ash.DataLayer` with CRUD, filter, sort, limit/offset, select,
  distinct, bulk_create, update_query/destroy_query, native aggregates,
  multitenancy, calculations, and relationship aggregates.
- Provides the `clickhouse` DSL, `AshClickhouse.Repo`, `AshClickhouse.Connection`,
  and `mix ash_clickhouse.setup` / `mix ash_clickhouse.migrate` tasks.
