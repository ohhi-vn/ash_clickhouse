# Changelog

## Unreleased

### Features

- **Data-skipping indexes.** Declare ClickHouse data-skipping indexes
  (`minmax`, `set`, `bloom_filter`, `ngrambf_v1`, `tokenbf_v1`) inside the
  `clickhouse` block via the repeatable `index` macro. They are emitted in the
  `CREATE TABLE` DDL and added to existing tables with `ALTER TABLE ... ADD
  INDEX IF NOT EXISTS` by `mix ash_clickhouse.migrate`. The index `type` is
  validated against a whitelist at compile time. See `guides/migrations.md` and
  `guides/resources.md`.

### Bug fixes

- **UUID heuristic no longer corrupts non-UUID string data.** Parameters are
  now converted to the 16-byte UUID binary form only when the column is
  provably UUID-typed (via `Dsl.uuid_attribute_names/1`), instead of whenever a
  36-character string merely *looked* like a UUID. This prevents legitimate
  `:string` business identifiers (order numbers, etc.) from being mangled on
  insert/update and in WHERE filters.
- **Removed dead `Module.get_attribute/2` fallbacks** in `resolve_table_name/1`
  and `repo/1`, which always raised (and were silently swallowed) at runtime.
  They now use `Dsl.table/1` / `Dsl.repo/1` directly.

### Improvements

- **Relationship aggregates are now batched.** `attach_aggregates/5` issues one
  grouped query per aggregate across the whole result set (instead of one query
  per record × aggregate), turning an N×M round-trip pattern into M round-trips.
  `has_many` / `has_one` relationship aggregates are now supported (previously
  only `belongs_to` worked; all others silently returned `default_value`).
- **Consistent, type-aware aggregate decoding.** `decode_aggregate/2` became
  `decode_aggregate/4`, which resolves the actual Ash attribute type of the
  aggregated field instead of sniffing the string's shape. This fixes
  `Decimal` columns being silently downgraded to `float` and mishandled
  scientific notation, and makes query-level and relationship aggregates return
  the same decoded type.
- **`raise_on_untranslatable_filter` now defaults to `true` (fail-closed).** An
  untranslatable filter on a `base_filter` (tenant scoping, soft-delete) is now
  raised rather than silently dropped, avoiding queries that are less
  restrictive than intended. Opt back into the old warning-only behaviour with
  `config :ash_clickhouse, :raise_on_untranslatable_filter, false`.
- **Repo cache can now be cleared** via `AshClickhouse.DataLayer.clear_repo_cache!/0`
  for test suites that redefine resources between tests.
- **Connection errors now log the message and stacktrace** before being
  swallowed as `{:error, _}`, and `Connection.stop/1` logs a debug message on
  shutdown instead of silently masking failures.
- **`truncate_integer/1` renamed to `validate_integer!/1`** to reflect that it
  validates/parses rather than truncates.
- **Documented** the intentional difference between strict `sanitize!/1`
  (table/database names) and `quote_name/1` (column identifiers), and marked
  the unused `group_by` query field as dead scaffolding.

## 0.1.0

- Initial release of AshClickhouse, an Ash data layer for ClickHouse.
- Implements `Ash.DataLayer` with CRUD, filter, sort, limit/offset, select,
  distinct, bulk_create, update_query/destroy_query, native aggregates,
  multitenancy, calculations, and relationship aggregates.
- Provides the `clickhouse` DSL, `AshClickhouse.Repo`, `AshClickhouse.Connection`,
  and `mix ash_clickhouse.setup` / `mix ash_clickhouse.migrate` tasks.
