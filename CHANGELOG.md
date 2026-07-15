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

- **`create_database/1` / `drop_database/1` no longer target a database named
  `nil`.** When a repo has no `:database` configured, these now fall back to
  ClickHouse's `default` database (matching `alter_table_cql/2`),
  so `mix ash_clickhouse.setup` no longer creates a literal `nil` database.
- **`Repo.child_spec/1` now honors its `opts` argument.** Options passed via
  the supervision tree (e.g. `{MyApp.Repo, url: "...", pool_size: 7}`) are
  merged into the connection options instead of being silently dropped.
- **`run_query/2` now guards against a missing repo.** A resource whose
  `clickhouse` block forgets `repo` raises a clear `ConfigurationError` instead
  of failing with `UndefinedFunctionError: function nil.query/3 is undefined`.
- **`distinct` + explicit `select` no longer silently drops columns.**
  `build_optimized_query/1` now emits the merged select list under `DISTINCT`
  (ClickHouse dedupes on the full row) rather than only the distinct columns.
- **Sort building now supports Ash's nulls-ordering directions**
  (`:asc_nils_first`, `:asc_nils_last`, `:desc_nils_first`, `:desc_nils_last`),
  emitting `NULLS FIRST` / `NULLS LAST`. Previously these raised
  `FunctionClauseError`.
- **The `index` DSL macro is now robust to key order.** It matches any keyword
  list and pulls `name`/`expression`/`type` with `Keyword.get`, raising a clear
  error if any required key is missing (instead of a cryptic "undefined
  function index/1" when keys were reordered). Duplicate index names now raise
  a compile-time `ArgumentError`.
- **`mix ash_clickhouse.migrate` is more resilient.** A single resource that
  raises during DDL generation no longer aborts the whole run, and a resource
  that forgets `repo` is skipped with an error instead of being migrated into
  every configured database.
- **Migration defaults support booleans, dates, datetimes, and `Decimal`
  structs.** These now emit correct literals instead of a misleading
  "Non-numeric default" error. Other unsupported default shapes raise a clearer
  "Unsupported default" message.
- **`stream/3` now wraps raw client exceptions** in
  `AshClickhouse.Error.ClickhouseError`, matching every other read path.
- **`qualified_table/1` (writes) now backtick-quotes the table name** like the
  read path, so a reserved-word table name behaves consistently across reads
  and writes.
- **`can?/2` now has a single source of truth.** The 26 redundant per-atom
  clauses that duplicated the `@supported_features` MapSet were removed; only
  the genuinely special cases (aggregates, joins, `:filter_expr`, and the
  explicit `false` clauses) remain.
- **`Dsl.get_config/3` no longer rescues an unreachable `FunctionClauseError`.**
- **`Identifier.valid_identifier?/1` is now just the regex** (the manual
  first-character check was redundant).
- **`collect_columns/1` now handles `:not` expressions** (both
  `%Ash.Query.BooleanExpression{op: :not}` and `%Ash.Query.Not{}`), matching
  `build_predicate/1`.

### Improvements

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
