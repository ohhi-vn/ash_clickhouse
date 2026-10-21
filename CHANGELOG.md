# Changelog

## 0.8.0

### Features

- **Expression calculations are evaluated by the data layer.** `add_calculations/3`
  and `add_calculation/4` are implemented, so the expression is pushed into the
  ClickHouse `SELECT` list as an aliased expression and the database computes
  the value. The calculated value is reported on the record's `calculations`
  map, decoded with the calculation's declared type. A calculation the layer
  cannot translate is evaluated against the decoded record instead.
- **`calculate/3` has the behaviour's shape.** The callback now takes
  `(resource, exprs, context)` — as `Ash.DataLayer` specifies — and evaluates
  the expressions against the record the context's primary key identifies,
  returning one value per expression.
- **Filter expressions are translated from Ash's real expression shapes.** The
  query builder now matches the concrete `%Ash.Query.Operator.*` and
  `%Ash.Query.Function.*` structs, so `!=` (`%Ash.Query.Operator.NotEq{}`),
  `contains/2`, `string_starts_with/2`, `string_ends_with/2`, `has/2` and
  `intersects/2` all translate to ClickHouse predicates. The legacy
  `{op, name, right}` shape still reaches the same translation.
- **`can?({:filter_expr, expr})` is answered precisely.** The layer reports
  support only for the expressions it can translate, so an unsupported filter
  is refused when the query is built — with an error naming the expression —
  instead of failing later with an opaque `QueryError`.
- **Aggregates honour their own `filter`, `sort` and `join_filters`.** A
  filtered aggregate counts the rows that match its own filter rather than every
  row, and a `first`/`list` aggregate honours its sort.
- **Aggregates are de-duplicated.** Ash calls `add_aggregates/3` twice with the
  same list; the aggregate is now issued once, so a read loading N relationship
  aggregates issues N aggregate queries instead of 2N.
- **The `:first`, `:list` and `:exists` aggregate kinds are supported**, both
  as `{:aggregate, kind}` and `{:query_aggregate, kind}`.
- **Relationship filters and aggregates are supported.** A filter that reaches
  into a related resource is answered with a semi-join — the queried
  resource's key is tested against a subquery over the related table — so the
  number of returned rows does not depend on how many related rows match. An
  aggregate over a relationship is computed with one grouped query for the
  whole result set, so a resource declaring one compiles.
- **Unrelated existence checks are supported**, answered with
  `EXISTS (SELECT 1 ...)`.
- **Combination queries are supported**, run as a single `UNION` statement
  against the database.
- **`Ash.Query.distinct_sort/2` is supported**, rendered with ClickHouse's
  `LIMIT 1 BY`.
- **`Ash.Query.timeout/2` is supported**, mapped onto the `max_execution_time`
  setting. The timeout is read from the query's context.
- **`default_bulk_batch_size/2` is declared**, so Ash's own chunking matches
  the layer's internal insert batching.
- **Sorting by an expression calculation is supported**: the calculation is
  projected into the select list and ordered by its alias.
- **The layer publishes its ClickHouse functions** through `functions/1`, so a
  filter can use a ClickHouse-specific function that Ash does not provide —
  `match/2` is published today.

### Bug fixes

- **Reading a resource that declares an expression calculation no longer
  raises.** `can?(:expression_calculation)` reported support while
  `add_calculations/3` and `add_calculation/4` were not implemented, so Ash
  fell through to `apply(data_layer_module, :add_calculation, ...)` and every
  read of such a resource failed with an `UndefinedFunctionError`.
- **The one-off calculation no longer raises a `MatchError`.** `calculate/3`
  had the same arity as the behaviour's callback but its arguments in the wrong
  order, so Ash called it with the resource first and the layer tried to match
  it against a data layer query.
- **A `!=` filter no longer raises `AshClickhouse.Error.QueryError`.** Ash
  represents `!=` as `%Ash.Query.Operator.NotEq{operator: :!=}`, which the
  query builder only matched under the `:not_eq` spelling.
- **A function-shaped filter no longer raises `AshClickhouse.Error.QueryError`.**
  `contains(name, "bo")` and the other `%Ash.Query.Function.*` predicates were
  not translated at all.
- **A filtered aggregate no longer reports the wrong count.** An aggregate's own
  `filter:` was never read, so `count :paid_count, [], filter: [status: "paid"]`
  counted every row.
- **An aggregate is no longer issued twice.** Ash calls `add_aggregates/3` twice
  with the same list and the layer did not de-duplicate it, so a read loading N
  relationship aggregates issued 2N ClickHouse queries.
- **A resource declaring an aggregate over a relationship no longer fails to
  compile** with "is not aggregatable".
- **`Ash.Query.distinct_sort/2` and `Ash.Query.timeout/2` no longer raise.**
  Both were refused because the layer reported them as unsupported.
- **A combination query is no longer refused.** `can?(:combine)` reported
  `false`, which made `Ash.DataLayer.combination_of/3` return "Data layer does
  not support combining queries".

### Documentation

- The data layer's moduledoc and `guides/limitations.md` no longer claim that
  combination queries are "executed by Ash in memory" — that fallback does not
  exist in Ash 3.33. Both now describe the delivered behaviour.

## 0.7.9

### Bug fixes

- **A `DateTime64` column declared without an explicit precision is no longer
  written as a bare integer.** The encoder decided between the `DateTime64`
  form and the plain-`DateTime` form by matching the literal `"DateTime64("`
  against the resolved column type, so a column declared as `DateTime64` —
  whose ClickHouse precision defaults to 3 — did not match and fell through to
  the plain-`DateTime` branch. It was written as a bare JSON *integer* number
  of seconds, which is the form ClickHouse's numeric interpretation does not
  pin down: with `input_format_read_datetime_number_as_raw_value = 1` (or
  `compatibility = '26.7'`) a bare integer is read as the column's raw value —
  ticks at the column precision — not as seconds. Measured against ClickHouse
  26.9.20.23, the old form stored `2024-01-02 03:04:05.000` by default but
  **`1970-01-20 17:22:44.645`** with that setting enabled; the new form
  stores the same instant under both configurations. The old form also
  silently dropped the value's microseconds, being whole seconds.
  `DateTime64` columns are now recognised whatever their declaration —
  `DateTime64`, `DateTime64(N)`, `DateTime64(N, 'UTC')` — and use the quoted
  decimal Unix-seconds string every `DateTime64` column already used.

## 0.7.8

### Bug fixes

- **`Ash.bulk_create/4` no longer raises when the caller asks for the inserted
  records back.** With `return_records?: true` — or `notify?: true`, which
  makes Ash ask for the records so the action's notifiers can read them — the
  bulk path raised `Ash.Error.Unknown` wrapping
  `BadMapError: expected a map, got: nil`, *after* the rows had already been
  written to ClickHouse. The cause was the data layer returning records with
  no bulk correlation metadata: Ash matches a returned record back to the
  changeset that produced it through `__metadata__.bulk_action_ref` /
  `bulk_create_index`, and with neither present the lookup found nothing and
  the write failed. Returned records now carry that metadata, the way
  `Ash.DataLayer.Ets` and `AshScylla` already do.
- **Records returned by `bulk_create` now carry the values that were
  submitted, not the wire encoding.** The data layer was rebuilding the
  returned record from the *encoded* rows it sent to ClickHouse, so a
  `:utc_datetime` attribute came back as the string `"1704164645.123456"`
  instead of a `%DateTime{}` and a `:date` attribute as the integer `19724`
  instead of a `%Date{}`. The single-record `create` path already returned the
  submitted values; the bulk path now agrees with it.

## 0.7.7

### Bug fixes

- **`DateTime64` inserts now send a quoted decimal Unix-seconds string.** 0.7.5
  sent fractional Unix seconds as a JSON *number*, but ClickHouse's numeric
  interpretation of a `DateTime64` value is not stable: 26.8 changed a bare
  integer from raw ticks to seconds, and `input_format_read_datetime_number_as_raw_value`
  toggles the reading. On affected 26.9 servers the value is rejected with
  `Code: 407 DECIMAL_OVERFLOW` (`Numeric value is out of range for DateTime64`)
  while the async-insert buffer is read. The encoder now writes
  `"<whole-seconds>.<six-digit-microseconds>"` (for example `"1704164645.123456"`),
  which ClickHouse's `basic` and `best_effort` date/time text parsers accept
  deterministically, independent of version, numeric-input settings, and time
  zone. Plain `DateTime` columns still use integer epoch seconds; `Date` and
  `Time` are unchanged.

## 0.7.6

### Remove duplicated logger

Update error & warning log in handle_result to avoid duplicated message.

## 0.7.5

### Bug fixes

- **Bulk `DateTime64` writes now send fractional Unix seconds.** 0.7.4's
  precision-aware encoder emitted raw scaled tick counts (integer microseconds
  for `DateTime64(6)`), but ClickHouse's `FORMAT JSONCompactEachRow` input reads
  a `DateTime64` JSON number as *seconds*, so every timestamp write failed with
  `Code: 407 DECIMAL_OVERFLOW` (or landed near 1970 for smaller values). The
  bulk encoder now writes `DateTime64` values as fractional seconds, which
  ClickHouse accepts while preserving microseconds; the column's own precision
  decides any truncation. `DateTime` columns still use integer epoch seconds, and
  `Date`/`Time` are unchanged.

### Downstream

- **`clickhouse_ex_logger` must raise its `ash_clickhouse` floor from `~> 0.7.4`
  to `~> 0.7.5`.** Its in-flight `collapse-insert-to-ash-bulk-create` change
  removed the ISO-8601 timestamp workaround on the false premise that 0.7.4
  fixed this encoding; until it depends on 0.7.5 the collapse cannot write
  timestamps.

## 0.7.4

- **Failed to write DateTime type when using `Ash.bulk_create/4`.**

### Bug fixes

## 0.7.3

### Compatibility

- **Ash 3.33 / Elixir 1.20 support.** Ash 3.33 requires applications to set
  `config :ash, default_string_length_count` (recommended: `:codepoints`, which
  matches how SQL data layers count string length) once any resource declares a
  `:string` attribute; this repo's test suite now does so in
  `config/config.exs`. Test support files were also aligned with the stricter
  Ash 3.33 compile-time verifiers (domains defined after their resources, fully
  qualified module references in DSL blocks) to keep the suite warning-free
  under Elixir 1.20's parallel checker.

### Improvements

- **Removed unreachable clauses flagged by Elixir 1.20 type checking** (no
  behavior change): the dead `{:error, {:already_started, _}}` clause in
  `Release.ensure_repo_started/1` (`Connection.start_link/1` already normalizes
  that case to `{:ok, pid}`), the unused bare atom/binary fallback clauses of
  `QueryBuilder.ref_name/1`, and the redundant empty-list clause of
  `DataLayer.build_where_clause/2`, plus an unused `require Logger` in
  `Telemetry`.

## 0.7.2

### Bug fixes

- **Resource metadata caching no longer fails when the ETS table is missing.**
  The `:ash_clickhouse_resource_metadata` table is now initialized at
  application startup and owned by the long-lived application process, so it
  is not removed when the request process that first reads resource metadata
  exits.

## 0.7.1

### Bug fixes

- **Recording applied migrations no longer fails.** `record_applied/2` passed
  the version as a scalar param to `INSERT INTO schema_migrations ... VALUES (?)`,
  but the client treats params of any `INSERT` as bulk rows (each must be a
  list, and `?` placeholders are never substituted there) — so applying any
  migration crashed with a `FunctionClauseError` (surfacing as a
  `ClickhouseError`) even though the DDL itself had succeeded. The version is
  now written through the same row-encoding path as data-layer inserts:
  `repo.insert_rows(statement, [[version]])` with `FORMAT JSONCompactEachRow`.
- **Migration discovery finds files another extension already loaded.** During
  `mix ash.migrate`, sibling extensions require every `.exs` under
  `priv/repo/migrations`, and `Code.require_file/1` returns nothing for files
  already required in the VM — so AshClickhouse discovered zero modules and
  reported "No pending migrations" against an empty tracking table. Discovery
  now falls back to resolving the already-loaded module from the file's
  `defmodule` name via `Code.ensure_loaded`.

## 0.7.0

### Features

- **`contains` is now configurable as case-sensitive** via
  `config :ash_clickhouse, :case_sensitive_contains, true` (uses `position()`
  instead of `positionCaseInsensitive()`), matching the case-sensitivity of
  `starts_with`/`ends_with`. Defaults to the historical case-insensitive
  behaviour.
- **`like` / `ilike` filters are now supported**, translating to ClickHouse
  `LIKE` / `ILIKE`.
- **Ash NewTypes are unwrapped in DDL type mapping.** A NewType wrapping e.g.
  `:uuid` now maps to `UUID` instead of silently becoming a `String` column;
  truly unknown types fall back to `String` with a warning.
- **Typed array attributes encode element values natively.** For arrays like
  `{:array, :integer}` elements are passed through so the client emits native
  JSON numbers; only string-ish element types are stringified.
- **Added GitHub Actions CI workflow** (`.github/`).

### Bug fixes

- **`Connection.query/4` no longer swallows genuine bugs.** Only client error
  modules (including `ArgumentError` from the client) are converted to a
  normalized error tuple; any other exception propagates with its original
  stacktrace instead of being mislabelled as a ClickHouse error.
- **Stale connection cache entries are cleaned up when the client process
dies.** `Connection` now monitors the client pid and erases the cached struct
  on `:DOWN`, so `get_conn/1` doesn't keep returning a dead pid.
- **`Connection.stop/1` only erases the cache entry after the client process
has been stopped** (or was already gone), so a failed stop leaves the cache
  intact for retry, and always returns `:ok`.
- **Empty `in` / `not_in` filter lists no longer produce invalid SQL.**
  `col IN ()` would be rejected by ClickHouse; these now emit semantically
  equivalent always-false / always-true literals.
- **DISTINCT queries with sorts on unselected columns are now valid SQL.** Sort
  columns missing from the SELECT list are appended automatically (ClickHouse
  requires every ORDER BY expression in the SELECT list for DISTINCT).
- **Rollback version deletion uses parameterized queries** instead of manual
  string escaping (`delete_applied/2`).
- **`Rollback stop comparison handles mixed-width numeric versions.** Versions
  are compared numerically when both parse as integers, falling back to
  lexicographic order for timestamp-style versions.
- **Batched relationship-aggregate failures now raise by default**
  (`QueryError`) instead of silently falling back to `default_value` — wrong
  numbers in reports are usually worse than a loud error. Opt out with
  `config :ash_clickhouse, :raise_on_aggregate_failure, false`.
- **`avg` over Decimal columns keeps precision.** Aggregate decoding now uses
  the field's attribute type for `avg` too, decoding back to `Decimal` instead
  of losing precision as a float.
- **Single-row update/destroy default to `mutations_sync: 1`**, giving
  read-your-writes semantics so the returned record reflects the change
  immediately.

### Improvements

- **`insert_rows/4` drops the unused `table` argument** (breaking change):
  `repo.insert_rows(statement, rows, opts)` — the table was already embedded in
  the statement. `Repo` behaviour and `DataLayer` call sites updated.
- **Per-resource metadata caching.** `uuid_attribute_names/1`,
  `atom_attribute_names/1`, and `attr_type_map/1` results are cached per
  resource in an ETS table, so hot paths like per-row record decoding and bulk
  value encoding don't re-scan resource attributes on every call.

- **Standard Ash mix tasks.** `AshClickhouse.DataLayer.Extension` now implements
  `Spark.Dsl.Extension` with `codegen/1` and `migrate/1`, so `mix ash.codegen`
  (print pending DDL, with `--dry-run` / `--check` support) and `mix ash.migrate`
  (apply DDL) work out of the box. `mix ash_clickhouse.migrate` now delegates to
  the same `migrate/1`, keeping both commands in sync.
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
- **Split the mono-module `data_layer.ex` into focused modules** under
  `AshClickhouse.DataLayer.*`: `Insert` (value encoding + insert/update SQL),
  `Record` (row → Ash record decoding), `Aggregate` (native + batched
  relationship aggregates), and `Calculations` (in-memory calculation
  application). The public API is unchanged.
- **`Connection.query!/4` now reraises a wrapped `ClickhouseError`** (instead of
  re-raising a fresh one), preserving the original stacktrace while still
  normalizing client errors.
- **`QueryBuilder.build_where_clause/2` no longer grows params quadratically.**
  The `params ++ mapped` append inside the reduce was replaced with prepend +
  single `Enum.reverse()`/`Enum.concat()`, so building WHERE clauses is now
  linear in the number of filters.
- **Shared mix-task helpers.** `find_repos/0` / `find_resources/0` moved into
  `Mix.Tasks.AshClickhouse.Helpers`, removing the duplication between
  `mix ash_clickhouse.setup` and `mix ash_clickhouse.migrate`.

## 0.1.0

- Initial release of AshClickhouse, an Ash data layer for ClickHouse.
- Implements `Ash.DataLayer` with CRUD, filter, sort, limit/offset, select,
  distinct, bulk_create, update_query/destroy_query, native aggregates,
  multitenancy, calculations, and relationship aggregates.
- Provides the `clickhouse` DSL, `AshClickhouse.Repo`, `AshClickhouse.Connection`,
  and `mix ash_clickhouse.setup` / `mix ash_clickhouse.migrate` tasks.
