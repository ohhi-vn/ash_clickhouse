# Design

## Context

See `proposal.md` for the motivation. This section records only the technical facts that constrain the approach.

**The `can?/2` surface is the contract.** Ash consults `Ash.DataLayer.can?/2` at *query-build* time to decide what to accept (`deps/ash/lib/ash/filter/filter.ex:3596` for `{:filter_expr, expr}`, `:3669` for `{:filter_relationship, rel}`, `:3114` for `{:exists, :unrelated}`, `:4348` for `:distinct_sort`, `:973` in `query.ex` for `:timeout`). It is also consulted at *compile* time by resource verifiers (`validate_aggregates_supported.ex:79` for `{:aggregate_relationship, rel}`). So a capability answer is checked in two different phases, and getting it wrong produces either a runtime crash or a compile-time rejection.

**Three Ash callbacks have no graceful fallback.** `add_calculations/3` falls through to `apply(data_layer_module, :add_calculation, ...)` (`data_layer.ex:1460`), which raises `UndefinedFunctionError` if the layer exports neither. `update_many/3` is called via `apply/3` with no default. `combination_acc/1` falls back to returning the *data layer module* as a sentinel meaning "no native accumulator" (`data_layer.ex:1228`). These are the callbacks where implementing vs. declining is a real choice.

**The current SQL builder is predicate-shaped.** `QueryBuilder.build_predicate/1` returns `{sql, column, params}` — a `column` is carried so `Types.convert_uuid_param/3` can convert a string parameter into the 16-byte binary form for UUID-typed columns (`query_builder.ex:170-197`). Any new translation must preserve that column-tagging, or UUID filters silently compare a 36-char string against a `UUID` column.

**The `SELECT` list is a flat list of atoms.** `resolve_select_columns/2` maps each to a quoted name, and `Record.to_ash_record/3` zips the row against `query_columns/1` positionally. Pushing a calculation into the `SELECT` list means the list must carry an *expression* and an *alias*, not just a column name — and the decode path must know which result column is a calculation rather than an attribute.

**ClickHouse settings reach the server through the client's `settings:` opt**, which the `clickhouse` client merges into the request URL (`deps/clickhouse/lib/clickhouse/interface/http/client.ex:173-198`). The layer already uses this channel for `mutations_sync` (`data_layer.ex:884`).

**Ash calls `add_aggregates/3` twice** with the same list (`query.ex:4545` and `read.ex:1804`), and neither de-duplicates. `Aggregate.attach/5` maps over the aggregate list calling `batched_values/7` *inside* the mapping function (`aggregate.ex:50-53`), so a duplicate costs a full extra query.

**Aggregate filters live in `aggregate.query.filter`** as an `%Ash.Filter{}` — not in the outer query's filter list — and `aggregate.join_filters` is a `%{path => filter}` map. `Aggregate.run/6` and `batched_related/7` never read either.

## Goals / Non-Goals

**Goals:**

- Make every `can?/2` answer truthful, in both the compile-time and query-build phases.
- Translate Ash's *actual* expression shapes — the `%Ash.Query.Operator.*` and `%Ash.Query.Function.*` structs — rather than the legacy `{operator, name, right}` maps the builder was written against.
- Preserve the UUID parameter-conversion contract in every new translation path.
- Keep one HTTP round-trip per logical operation. The layer talks to ClickHouse over HTTP, so round-trip count is the dominant latency factor.
- Keep the change additive: no existing behaviour that works today may regress.

**Non-Goals:**

- Changing the `clickhouse` DSL surface. `default_bulk_batch_size/2` returns the layer's existing constant; it does not add a DSL option. (A DSL option is a separate, easily-merged follow-up.)
- Rewriting the query builder. The existing column-tagging contract is load-bearing for UUID handling and is preserved, not replaced.
- Supporting `upsert`, full `JOIN`, lateral joins, or `update_many` — see `proposal.md` for why.

## Decisions

### D1. Translate the real Ash expression structs, and make `can?({:filter_expr, expr})` a precise whitelist

**Decision.** Replace the legacy-shape matching in `build_predicate/1` with matching on the concrete Ash structs: `%Ash.Query.Operator.{Eq,NotEq,GreaterThan,GreaterThanOrEqual,LessThan,LessThanOrEqual,In,IsNil,Has,Overlap}{}` and the predicate `%Ash.Query.Function.*` structs. The `can?({:filter_expr, expr})` clause inspects the *same* struct and returns `true` only when a matching translation exists.

**Why.** Ash calls `can_filter_expr?/2` with the fully-formed operator/function struct (`filter.ex:3747`, `:3287`, `:3977`), so the layer can answer precisely rather than blanket-`true`. This directly converts a runtime `QueryError` into a query-build error naming the operator.

**Alternative considered.** Keep blanket-`true` and let the builder raise. Rejected: the failure surfaces during SQL construction, after authorization and query planning, with an error that does not name the operator as unsupported — the current `QueryError` says "dropping untranslatable filter", which reads like a bug rather than an unsupported-feature report.

**Consequence.** The legacy `{op, name, right}` clause is retained as a fallback for filters Ash still produces in that shape (e.g. `set_tenant/3` synthesises `%{name: attribute, op: :eq, right: %{value: tenant}}` at `data_layer.ex:410`). Both shapes must map to the same translation, so the translation functions are keyed on a normalized `(operator, column, value)` triple rather than on the struct directly.

### D2. Function translation is a table keyed by the function struct, with ClickHouse SQL per entry

**Decision.** A `functions` map in the query builder maps each supported `%Ash.Query.Function.*{}` struct to a ClickHouse SQL template. Templates are parameterised by position: `contains` → `positionCaseInsensitive(<col>, ?) > 0`, `string_starts_with` → `<col> LIKE ? ESCAPE '\'`, `has` → `has(<col>, ?)`, `intersects` → `arrayIntersect(<col>, <col>)`.

**Why.** Each function has a different arity and argument kinds (column vs. column vs. literal), so a uniform positional template keeps the translation data-driven rather than a growing `case` over structs. The existing `escape_like/1` helper already handles wildcard-literal escaping for prefix/suffix matching, and is reused.

**Alternative considered.** Translate `contains` to `LIKE '%x%'`. Rejected: the existing behaviour is a case-insensitive substring search by default (`case_sensitive_contains?/1`, `query_builder.ex:311`), configurable via `config :ash_clickhouse, :case_sensitive_contains, true`. Changing it to `LIKE` would silently change existing results.

### D3. Expression calculations are pushed into the `SELECT` list as aliased expressions

**Decision.** `add_calculations/3` and `add_calculation/4` translate the calculation's expression into a SQL fragment and add it to the query's select list as `{name, sql}`. The builder emits `<sql> AS <quoted name>`, and the decode path routes the resulting column into the record's `calculations` map rather than into an attribute.

**Why.** This is the actual feature win — the calculation is computed by ClickHouse, not by shipping rows to the BEAM and evaluating there. It also matches how Ash's own `Ash.Query.Function.Type` wrapper expects a typed value: the expression tree Ash hands over for `expr(name)` with a declared type is `%Ash.Query.Function.Type{arguments: [ref, :string, []]}`, so the translator must handle the type wrapper by casting the inner expression.

**Alternative considered.** Set `can?(:expression_calculation) -> false` and let Ash evaluate in Elixir. This is a two-line change that unblocks the crash. Rejected as the *whole* fix because the requirement is to support the feature — but it is the fallback behaviour for any expression the translator cannot handle (see D4).

### D4. A calculation the translator cannot express falls back to evaluation against the record

**Decision.** When the translator cannot render an expression, the calculation is *not* pushed down; instead the layer records it for evaluation against each decoded record, using the same expression tree Ash provided.

**Why.** Ash's read path tolerates a calculation missing from the data layer's result: `compute_expression_at_runtime_for_missing_records/3` (`read.ex:2107`) re-runs any record marked `missing_from_data_layer` through `Ash.Actions.Read.Calculations.run/4`. Pushing down what we can and evaluating the rest keeps the feature working for every expression, rather than failing the read for the subset we cannot translate.

**Alternative considered.** Fail the read for an untranslatable expression. Rejected: it would make the feature narrower than it needs to be, and the fallback already exists in the framework.

### D5. `calculate/3` is corrected to the behaviour's shape and implemented as an in-memory evaluation

**Decision.** Rename the current `calculate/3` (which stores a calculation into the query context) to a private helper with a distinct name, and implement the public `calculate/3` as `(resource, exprs, context)`, evaluating the expressions against the record identified by the context's primary key.

**Why.** The behaviour's spec is `calculate(Ash.Resource.t(), list(Ash.Expr.t()), context :: map) :: {:ok, term} | {:error, term}` (`data_layer.ex:341-342`), and the wrapper validates the return against `{:ok, _} | {:error, _}` (`data_layer.ex:467-476`). Ash calls it with `resource` first (`calculations.ex:152`), which is why the current implementation raises `MatchError`. The context carries `primary_key` and `calculation_context` (`calculations.ex:155`).

**Alternative considered.** Decline `:calculate` entirely (`can?(:calculate) -> false`). Ash then reports "Data layer does not support one-off calculations" (`calculations.ex:164`) — an honest error, but the layer already claims `:calculate` in `@supported_features`, so declining it is a capability regression. Implementing it is the smaller change and keeps the advertised surface.

### D6. Relationship filters become semi-joins (`IN (SELECT ...)`), not joins

**Decision.** A filter whose left side is a reference with a non-empty `relationship_path` is translated into a subquery on the related table, with the outer predicate testing the join key against that subquery's result.

**Why.** A full `JOIN` changes row cardinality: a customer with three matching orders would appear three times, which breaks Ash's record-count semantics and would need a `DISTINCT` to undo — expensive on a columnar store, and wrong for `has_one`/`belongs_to`. A semi-join preserves cardinality exactly.

Ash hands the layer the relationship path in the reference struct (`%Ash.Query.Ref{relationship_path: [:orders], resource: ProbeOrder}`, verified by probing `Ash.Filter.hydrate_refs/2`). The path is resolved via `Ash.Resource.Info.relationship/2` to find the join key on each side.

**Alternative considered.** Implementing `{:join, _}`. Rejected — see `proposal.md`.

**Consequence.** Only *single-hop* relationship paths are supported. A multi-hop path would need nested semi-joins; the layer reports non-support for those so Ash refuses the filter at build time.

### D7. Unrelated `exists/2` becomes `EXISTS (SELECT 1 ...)`

**Decision.** `%Ash.Query.Exists{related?: false, resource: R, expr: e}` is translated to `EXISTS (SELECT 1 FROM <R's table> WHERE <e>)`.

**Why.** This is the direct SQL analogue, and ClickHouse supports `EXISTS` subqueries. The inner expression is translated with `R` as the resource context, so its columns resolve against `R`'s table.

**Note.** The layer's `can?({:exists, :unrelated})` is consulted at `filter.ex:3114` *before* the expression is hydrated, so the answer must be `true` for the filter to be accepted at all. Declining it makes Ash raise a bare `RuntimeError` ("Data layer does not support unrelated exists expressions") rather than a clean query error.

### D8. Aggregate filters and sorts are merged into the aggregate's own query

**Decision.** `Aggregate.run/6` and `batched_related/7` read `aggregate.query.filter` and `aggregate.query.sort` and merge them into the aggregate's `WHERE`/`ORDER BY` — translated against the *target* resource of the aggregate, not the source.

**Why.** The aggregate's filter references the aggregated resource's attributes, so it must be built with that resource's table and column types. This is also where the UUID column-tagging matters: the aggregate's `IN (...)` clause is already built with `build_in_clause/3` and `Types.convert_uuid_param/3` (`aggregate.ex:298-302`), and the filter's own parameters need the same treatment.

**Alternative considered.** Rely on `can?(:aggregate_filter)`/`can?(:aggregate_sort)`. Rejected: Ash 3.33 never checks them — they are inert legacy flags. The fix has to be in the aggregate code.

### D9. Aggregates are de-duplicated by name at the point they are added

**Decision.** `add_aggregate/3` and `add_aggregates/3` de-duplicate by aggregate name, and the aggregates move from `context[:aggregates]` to a dedicated field on `%AshClickhouse.Query{}`.

**Why.** Ash calls `add_aggregates/3` twice with the same list; de-duplicating at insertion makes the second call a no-op regardless of which call site runs last. The struct already has an `aggregates: []` field (`query.ex:38`) that is currently unused — the code reads and writes `context[:aggregates]` instead. Moving to the field removes the clobbering risk: `set_context/3` merges the caller's context over the existing one (`data_layer.ex:427`), so an inbound `:aggregates` key in the context would silently discard the query's aggregates.

**Alternative considered.** De-duplicate in `Aggregate.attach/5` only. Rejected: it would fix the doubled query but leave the context-clobbering hazard and the unused struct field.

### D10. `distinct_sort` is implemented with `LIMIT 1 BY`

**Decision.** A query with a distinct sort is rendered as `SELECT <distinct cols> ... GROUP BY <distinct cols> ORDER BY <distinct sort> LIMIT 1 BY <distinct cols>`.

**Why.** `LIMIT n BY expr` is ClickHouse's exact equivalent of Postgres's `DISTINCT ON (expr)` — it keeps `n` rows per distinct value of `expr`, taking the first in the query's output order. Since the `ORDER BY` controls that order, the requested sort determines which row is kept.

**Trade-off.** `GROUP BY` is ClickHouse's primary aggregation primitive and is materially more expensive than `SELECT DISTINCT` on a wide, high-cardinality column. This is inherent to `DISTINCT ON` semantics, not an artefact of the implementation.

**Note.** `LIMIT 1 BY` and `SELECT DISTINCT` are mutually exclusive in one statement, so a query with both a distinct sort and a plain distinct uses the `GROUP BY` form.

### D11. `timeout` maps onto ClickHouse's `max_execution_time`

**Decision.** `can?(:timeout)` becomes `true`; the query's timeout is threaded into the request's `settings:` as `max_execution_time`, in seconds, and merged with the existing `mutations_sync` setting.

**Why.** `Ash.Query.timeout/2` currently hard-errors with `Ash.Error.Query.TimeoutNotSupported` (`query.ex:973-978`) because the layer does not claim `:timeout`. ClickHouse enforces `max_execution_time` server-side, which stops the query rather than letting the client hang — the behaviour a caller asking for a timeout wants.

**Trade-off.** `max_execution_time` is server-side and coarse-grained; a client-side timeout remains Ash's own responsibility (`Ash.ProcessHelpers.task_with_timeout`, `read.ex:1625`). Ash's timeout is in milliseconds, ClickHouse's setting in seconds, so the conversion rounds up.

**Note.** `Ash.Query.timeout/2` requires `can?(:timeout)` but the *value* is not on the `Ash.Query` struct's data-layer path — the timeout lives on the `Ash.Query`, and the data layer query is built separately. The value reaches the layer through `Ash.Query.data_layer_query/2`'s context (`query.ex:4530-4539` merges `ash_query.context` into `set_context/3`), so the layer reads it from the context. The timeout is set on the `Ash.Query` by `read.ex:273-274` from `opts[:timeout] || query.timeout || action.timeout || domain.timeout`.

### D12. Combination queries build one statement per union, and the accumulator carries the SQL fragments

**Decision.** `combination_of/3` receives Ash's list of `{type, data_layer_query}` pairs and produces a single query holding the rendered SQL of each part. `combination_acc/1` returns the accumulated parts so a subsequent part can be appended.

**Why.** `combination_of/3`'s contract is to return *one* `data_layer_query` (`data_layer.ex:1174-1194`), but a union of N queries is N statements. The `data_layer_query()` type is opaque, so the layer's query struct must be able to represent "several statements to run in sequence". `combination_acc/1` exists precisely to let the layer carry state across parts — Ash threads the previous part's accumulator into the next part's context (`query.ex:4513-4527`).

**Note.** Ash validates that all parts select the same fieldset (`read.ex:1239-1247`), so the parts' `SELECT` lists are compatible.

**Trade-off.** ClickHouse does not guarantee output order across a `UNION ALL` without an explicit `ORDER BY` on the whole statement. The parts' individual `ORDER BY`s do not survive the union. The requirement therefore specifies the order the parts *produced*, which the layer preserves by keeping the parts' results in sequence.

### D13. Aggregate `:first`, `:list`, and `:exists` reuse the existing batched machinery

**Decision.** The three new kinds are implemented in `Aggregate` alongside the existing ones: `:first` → `ORDER BY <sort> LIMIT 1`, `:list` → collect the rows (with `arraySort` for the sorted variant), `:exists` → `SELECT 1 ... LIMIT 1` interpreted as a boolean.

**Why.** They reuse `batched_same_table/8` and `batched_related/7`, so the relationship aggregate's single-query-per-aggregate batching applies to them too. Implementing them as new aggregate kinds rather than as new SQL paths keeps the batched property intact.

### D14. The layer publishes ClickHouse functions through `functions/1`

**Decision.** `functions/1` returns a list of modules implementing `Ash.Query.Function` — one per ClickHouse-specific function the layer supports in filters — each of which the query builder can also render to SQL.

**Why.** `Ash.Filter.get_function/3` looks up custom functions by name via `Ash.DataLayer.data_layer_functions(resource)` (`filter.ex:5167`), so publishing a module is all that is needed for a caller to *write* the filter. Rendering it to SQL is the layer's own work, and it must recognise the same module.

**Note.** Each published module needs both an `Ash.Query.Function` implementation (so Ash can type-check and evaluate it) and a SQL rendering. The rendering lives in the query builder's function table, keyed by the module.

## Risks / Trade-offs

**[An Ash upgrade changes the expression structs]** → Ash 3.33's operator/function structs are the contract; the builder matches on them explicitly rather than on shapes. If a future Ash renames or restructures them, the translator's `can?({:filter_expr, expr})` answers change and previously-working filters are refused at build time — a loud failure, not a silent wrong result. Mitigation: the `can?` predicate and the translator share one table, so they cannot drift.

**[`GROUP BY` for `distinct_sort` is expensive]** → Inherent to `DISTINCT ON` semantics. Mitigation: `distinct_sort` is opt-in — a caller must ask for it, so the cost is only paid by callers who want the semantics. The plain `distinct` path keeps using `SELECT DISTINCT`.

**[Server-side timeout is coarse]** → `max_execution_time` is in seconds and enforced by the server, so a sub-second timeout is not honoured precisely. Mitigation: round up to the next second (never under-report the caller's intent), and leave Ash's own client-side timeout as the precise mechanism.

**[Pushing calculations down changes what the database computes]** → A calculation evaluated by ClickHouse may differ from one evaluated in Elixir (e.g. string functions, rounding, NULL handling). Mitigation: the type wrapper Ash supplies is rendered as an explicit cast, and the value is decoded through the calculation's declared type rather than the attribute's.

**[Semi-joins do not scale like joins do]** → `IN (SELECT ...)` re-executes the subquery per outer row in some plans, whereas a join hashes the right table once. Mitigation: ClickHouse's query planner will typically evaluate the subquery once for an uncorrelated `IN`; the semi-join is only used for relationship filters, which are the alternative to a manual denormalized table. This is the documented trade-off of preserving row cardinality.

**[Union output order is not guaranteed by the database]** → The layer preserves the order the parts produced (D12). Mitigation: the requirement is written in terms of the parts' order rather than the database's, so the guarantee is the layer's, not ClickHouse's.

**[De-duplicating aggregates changes the shape of the context]** → Moving aggregates out of `context[:aggregates]` into a struct field touches `run_query/2`, `stream/3`, and `run_aggregate_query/3`. Mitigation: all three read the same source; the change is mechanical, and the existing unit tests exercise all three.

**[Adding `can?` answers changes what Ash accepts]** → A caller relying on `can?(:expression_calculation) == true` today gets a crash; after this change they get a working read. A caller relying on `can?(:combine) == false` to detect unsupported combinations now gets a working one. Mitigation: this is the intent of the change; the proposal calls it out as the one behavioural break.

**[The `clickhouse` client merges `settings:` into the URL]** → Adding `max_execution_time` to the settings map changes the request URL. Mitigation: the client already appends `mutations_sync` the same way (`data_layer.ex:884`), so the mechanism is proven; both settings are merged into one map rather than passed separately.

## Migration Plan

No data migration. The change is entirely within the data layer's query construction and capability reporting.

**Deployment:** ship as a normal patch/minor release. Existing queries are unaffected — a filter that translated before still translates the same way (D1 keeps the legacy shape working), and the UUID parameter conversion is preserved on every path.

**Rollback:** revert the release. There is no schema change, no persisted state, and no partially-applied migration to unwind.

**Verification before merge:**
- Every new capability is exercised at the Ash action level (`Ash.read`, `Ash.Query.filter`, `Ash.Query.sort`, `Ash.aggregate`, `Ash.Query.combination_of`), not only at the data-layer callback level. The existing suite tests the callbacks directly, which is why these defects survived.
- The aggregate-filter case is asserted against a known row set, so a wrong count fails the test rather than passing silently.
- The duplicate-aggregate fix is asserted by counting the queries issued, not just the values returned.

## Open Questions

None. The scope boundaries, the ClickHouse SQL mappings, and the fallback behaviours are all decided above; remaining items are implementation details that do not change the specs or the task breakdown.
