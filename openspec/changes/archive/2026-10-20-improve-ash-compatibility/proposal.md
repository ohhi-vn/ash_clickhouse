# Proposal

## Why

`AshClickhouse.DataLayer` advertises Ash features it does not actually deliver. The gaps are not cosmetic — several are crashes on ordinary reads, and one produces **silently wrong numbers**.

Three defects are blockers:

1. **`can?(:expression_calculation)` returns `true`, but `add_calculations/3` and `add_calculation/4` are not implemented.** Ash has no graceful fallback for these (`Ash.DataLayer.add_calculations/3` falls through to `apply(data_layer_module, :add_calculation, ...)` → `UndefinedFunctionError`). **Every read of a resource that declares an expression calculation raises.** Verified against Ash 3.33.0 with `Ash.read(Resource, load: [:copied_name])` where `copied_name` is `expr(name)`.
2. **`calculate/3` has the wrong signature.** The behaviour is `calculate(resource, exprs, context)`; the layer implements `calculate(data_layer_query, calculation, resource)`. Same arity, so it compiles with `@impl Ash.DataLayer`, but Ash calls it with `resource` first — producing `MatchError: no match of right hand side value: SomeResource`.
3. **Filter translation only understands a legacy operator shape.** Ash 3.33 represents `!=` as `%Ash.Query.Operator.NotEq{operator: :!=}` (the layer only matches `:not_eq`) and represents string predicates as `%Ash.Query.Function.*{}` structs (the layer matches none of them). `name != "bob"` and `contains(name, "bo")` both raise `AshClickhouse.Error.QueryError` at query-build time.

Beyond the blockers, the layer **silently returns wrong numbers** for aggregate filters:

> `Ash.Resource.Aggregate`'s `filter:`, `sort:`, and `join_filters:` options are **never read**. `count :paid_count, [], filter: [status: "paid"]` returns the count of *all* rows — no error, no warning. The aggregate's own `WHERE` clause is built solely from the outer query's filters (`lib/ash_clickhouse/data_layer/aggregate.ex:22-34`, `:184-250`). The `can?(:aggregate_filter)` / `can?(:aggregate_sort)` flags cannot save this: Ash 3.33 **never checks them** — they are inert legacy flags superseded by the per-aggregate options, so the fix must live inside the aggregate code.

Two more compatibility gaps make ordinary Ash usage fail outright:

- **Relationship filters are rejected at compile time.** `count :order_count, :orders` fails the resource verifier with `AggCustomer.orders is not aggregatable`, because `can?({:aggregate_relationship, _})` returns `false` — even though `Aggregate.attach/5` already implements the batched grouped query for it.
- **`Ash.Query.distinct_sort/2` and `Ash.Query.timeout/2` hard-error.** The layer reports no `:distinct_sort` and no `:timeout`, so Ash adds a query error instead of running the query.

And one performance defect: `add_aggregates/3` is called **twice** by Ash (`deps/ash/lib/ash/query/query.ex:4545` and `deps/ash/lib/ash/actions/read/read.ex:1804`) and does not de-duplicate. Since `batched_values/7` runs *inside* the mapping function (`aggregate.ex:50-53`), a read loading N relationship aggregates issues **2N** ClickHouse round-trips instead of N — a direct latency multiplier on the OLAP path the layer exists to serve.

The through-line: **the layer's `can?/2` surface is not trustworthy.** It claims `:expression_calculation` and `{:filter_expr, _}` while lacking the code to serve them, and it denies features it could serve. This change makes the advertised feature surface match the delivered behaviour, and adds the Ash features ClickHouse's SQL engine expresses well.

## What Changes

### Correctness (blockers and silent wrongness)

- **Expression calculations are evaluated by the data layer.** `add_calculations/3` and `add_calculation/4` are implemented by pushing the calculation's expression into the ClickHouse `SELECT` list as an aliased expression, so `expr(name)` becomes a selected column. The `calculate/3` callback is corrected to the behaviour's `(resource, exprs, context)` shape.
- **Filter translation covers Ash 3.33's real expression shapes.** The `:!=` operator and the `%Ash.Query.Function.*{}` predicate structs (`contains`, `string_starts_with`, `string_ends_with`, `is_nil`, `has`, `intersects`, …) are translated to ClickHouse SQL.
- **`can?({:filter_expr, expr})` reports precisely.** It returns `true` only for expressions the layer can actually translate, so Ash rejects an unsupported predicate at **query-build time** with a clear message instead of accepting it and failing later with an opaque `QueryError`.
- **Aggregate `filter:`, `sort:`, and `join_filters:` are applied.** A filtered aggregate counts the rows that match its own filter, and `:first`/`:list` aggregates honour their `sort:`.
- **Aggregates are de-duplicated.** The same aggregate is issued once, restoring N round-trips for N aggregates.
- **Sorting by a calculation or an aggregate works.** Such a sort is projected into the `SELECT` list and ordered by its alias, instead of raising `FunctionClauseError` in `Identifier.quote_name/1`.

### New Ash features ClickHouse supports

- **Relationship filters and aggregates** — `can?({:aggregate_relationship, _})` and `can?({:filter_relationship, _})` become `true`. A relationship filter is answered with a **semi-join** (`WHERE "id" IN (SELECT ...)`), not a full `JOIN`, so row cardinality is unchanged and no `DISTINCT` is needed.
- **Unrelated `exists/2`** — `can?({:exists, :unrelated})` becomes `true`, answered with `EXISTS (SELECT 1 ...)`.
- **`Ash.Query.distinct_sort/2`** — supported via ClickHouse's `LIMIT 1 BY`, the exact equivalent of Postgres's `DISTINCT ON`.
- **`Ash.Query.timeout/2`** — supported, mapped onto ClickHouse's `max_execution_time` setting.
- **Combination queries** — `can?(:combine)` and `can?({:combine, :union_all})` become `true`, with `combination_of/3` and `combination_acc/1` building `SELECT … UNION ALL SELECT …`.
- **Additional aggregate kinds** — `:first`, `:list`, and `:exists` are supported (`LIMIT 1`, `groupArray`, `EXISTS`), for both `{:aggregate, kind}` and `{:query_aggregate, kind}`.
- **`default_bulk_batch_size/2`** — the layer declares its batch size so Ash's own chunking matches the layer's internal insert batching, instead of Ash's default of 100 silently overriding the layer's 1000.
- **`functions/1`** — the layer publishes ClickHouse SQL functions usable in filters.

### Documentation corrections

- The moduledoc and `guides/limitations.md` claim combination queries are "executed by Ash in memory". That fallback **does not exist** in Ash 3.33 — `can?(:combine)` being false makes `Ash.DataLayer.combination_of/3` return `{:error, "Data layer does not support combining queries"}`. The text is corrected to match reality (and to the new behaviour).
- The `@spec`s for `update_query/4` and `destroy_query/4` have their `resource` and `opts` arguments swapped relative to the behaviour.

Explicit non-goals:

- **`upsert` stays unsupported.** ClickHouse has no `ON CONFLICT`. The realistic substitute, `ReplacingMergeTree`, dedupes at *merge* time, so a read immediately after the upsert can see both rows. An upsert that silently returns stale data is worse than Ash's current honest "Upsert is not supported by the data layer" error. A `ReplacingMergeTree` mode, if wanted, should be a separate opt-in DSL flag with documented eventual-consistency semantics.
- **Full `{:join, _}` stays unsupported.** A `JOIN` changes row cardinality, which would break Ash's record-count semantics for `has_many` relationships, and ClickHouse's hash joins are memory-bounded. The semi-join covers the realistic use cases.
- **Lateral joins, `update_many`, `attribute_ecto_type`, and `Ash.DataLayer.Simple` are untouched.** ClickHouse has no `LATERAL`; `update_many`'s `multiIf` mutation is poor value on a columnar store; `attribute_ecto_type` is meaningless without an Ecto schema; and `Ash.DataLayer.Simple` filters and sorts in Elixir, which would replace SQL push-down entirely.

## Capabilities

### New Capabilities

- `filter-expressions`: How Ash filter expressions — operators, function structs, and relationship-scoped references — are translated into ClickHouse `WHERE` predicates, and how the layer reports which expressions it can express.
- `expression-calculations`: How expression calculations are evaluated by the data layer, including push-down into the `SELECT` list and the one-off `calculate/3` contract.
- `aggregate-queries`: The aggregate kinds the layer supports, how per-aggregate filters and sorts are applied, and how aggregates are batched into ClickHouse queries.
- `relationship-queries`: Filtering and aggregating across a relationship, expressed as semi-joins rather than full joins.
- `combination-queries`: Union-style combination queries across multiple Ash queries.
- `query-options`: Query-level options the layer honours — `distinct_sort` and `timeout`.

### Modified Capabilities

None. `bulk-create` is unaffected: the batch-size change only makes Ash's chunking agree with the layer's existing internal batching, which `bulk-create` already specifies.

## Impact

- **Code**: `lib/ash_clickhouse/data_layer.ex` (`can?/2`, the `filter`/`sort`/`select`/`aggregate`/`calculate` callbacks, new `add_calculations`/`add_calculation`/`distinct_sort`/`combination_of`/`combination_acc`/`default_bulk_batch_size`/`functions` callbacks), `lib/ash_clickhouse/data_layer/query_builder.ex` (operator and function translation, `ORDER BY` projection, `DISTINCT`/`LIMIT 1 BY`), `lib/ash_clickhouse/data_layer/aggregate.ex` (per-aggregate filters and sorts, de-duplication, new kinds), `lib/ash_clickhouse/query.ex` (a dedicated `aggregates` field and the fields the new callbacks need), and `lib/ash_clickhouse/data_layer/dsl.ex` if a new option is needed.
- **Behaviour**: `Ash.read/2` on a resource with an expression calculation stops raising and returns records. A read that loads N relationship aggregates drops from 2N to N ClickHouse queries. Filters and sorts that previously raised now run. Aggregate filters that previously returned wrong counts now return right ones.
- **Breaking**: none to the public Elixir API. The `can?/2` answers change, which is the point — but a caller that relied on `can?(:expression_calculation) == true` while avoiding expression calculations is unaffected. A caller relying on `can?(:combine) == false` to detect an unsupported combination now gets a working one.
- **APIs/dependencies**: no public API change; `ash ~> 3.33` and `clickhouse ~> 0.32` unchanged. The layer continues to speak the `Ash.DataLayer` behaviour it already implements.
- **Tests**: the suite has no coverage of expression calculations, relationship aggregates, aggregate filters, or combination queries at the Ash action level — which is why each of these defects survived. This change adds coverage at that level alongside the existing unit-level tests.
