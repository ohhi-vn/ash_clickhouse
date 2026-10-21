# Tasks

## 1. Filter expression translation

- [x] 1.1 In `lib/ash_clickhouse/data_layer/query_builder.ex`, replace the legacy-shape matching in `build_predicate/1` with matching on the concrete Ash structs (`%Ash.Query.Operator.{Eq,NotEq,GreaterThan,GreaterThanOrEqual,LessThan,LessThanOrEqual,In,IsNil,Has,Overlap}{}` and the predicate `%Ash.Query.Function.*` structs), normalising each into a shared `(operator, column, value)` triple so the legacy `{op, name, right}` shape — still produced by `set_tenant/3` at `data_layer.ex:410` — and the modern struct shape reach the same translation; verify `mix compile --warnings-as-errors` is clean and that the existing `test/unit/query_builder_test.exs` and `query_builder_filters_test.exs` still pass unchanged.

- [x] 1.2 Add the `:!=` operator to `build_comparison/3` alongside the existing `:not_eq`, keeping both spellings, so Ash's `%Ash.Query.Operator.NotEq{operator: :!=}` is translated to an inequality predicate; verify a new unit case asserts `name != "bob"` produces an inequality predicate with the literal bound as a parameter and not interpolated into the SQL text.

- [x] 1.3 Add the ClickHouse function translation table to the query builder — `contains` → `positionCaseInsensitive`/`position` (honouring the existing `case_sensitive_contains?/1` setting), `string_starts_with`/`string_ends_with` → `LIKE` with the existing `escape_like/1` wildcard escaping, `has` → `has()`, `intersects` → `arrayIntersect()`, and the null-test function → the null comparison — each rendering its literal arguments as bound parameters; verify a new unit case per function asserts the generated SQL fragment and its parameter list.

- [x] 1.4 Make `can?({:filter_expr, expr})` in `lib/ash_clickhouse/data_layer.ex` inspect the expression struct and answer `true` only for the operators and functions the translator can render, sharing the same table the translator uses so the two cannot drift; verify a new unit case asserts `true` for a supported operator, `true` for a supported function, and `false` for an unsupported expression.

- [x] 1.5 Add an action-level test proving an unsupported filter is refused when the query is built — the query is invalid, carries an error naming the unsupported expression, and no query reaches the database — alongside a case proving a supported filter yields a valid query; verify both cases pass by asserting on the query's `errors` and on the fake repo receiving no query.

- [x] 1.6 Add an action-level test that reading a resource filtered with `name != "bob"` and with `contains(name, "bo")` completes and returns the expected rows; verify the test fails against the pre-change implementation with `AshClickhouse.Error.QueryError` and passes with the change.

## 2. Expression calculations

- [x] 2.1 Extend `%AshClickhouse.Query{}` in `lib/ash_clickhouse/query.ex` to carry a select list that can hold either a plain column or a `{name, sql}` expression pair, and extend `QueryBuilder.resolve_select_columns/2` to render the expression form as `<sql> AS <quoted name>` while leaving the plain-column form unchanged; verify a unit case asserts the rendered `SELECT` list for both forms.

- [x] 2.2 Add a value-expression translator to the query builder that renders a calculation's expression tree to a SQL fragment — handling the `%Ash.Query.Function.Type{arguments: [expr, type, constraints]}` wrapper Ash supplies for a typed calculation by casting the inner expression, and the column references and literals within — binding literals as parameters; verify a unit case asserts the fragment rendered for `expr(name)` under a declared string type.

- [x] 2.3 Implement `add_calculations/3` and `add_calculation/4` in `lib/ash_clickhouse/data_layer.ex` so a translatable calculation's expression is pushed into the select list as an aliased expression, and an untranslatable one is instead recorded for evaluation against the decoded records; verify a unit case asserts the select list gains the aliased expression for a translatable calculation.

- [x] 2.4 Extend the decode path (`AshClickhouse.DataLayer.Record` and the column resolution in `lib/ash_clickhouse/data_layer.ex`) so a result column that carries a calculation is placed in the record's `calculations` map under the calculation's name rather than into an attribute, and so the remaining columns still decode positionally against the attribute list; verify a unit case asserts the record carries the calculated value under its name and its attributes are unchanged.

- [x] 2.5 Rename the existing `calculate/3` in `lib/ash_clickhouse/data_layer.ex` to a private helper with a distinct name, and implement the public `calculate/3` with the behaviour's `(resource, exprs, context)` signature, evaluating the expressions against the record identified by the context's primary key and returning one value per expression in the order requested; verify a unit case asserts the values returned for a single and for a multi-expression request, and that an expression that cannot be evaluated returns an error rather than a value.

- [x] 2.6 Add an action-level test that reading a resource with an expression calculation completes, returns records, and that each record carries the calculated value equal to what the expression yields from the stored attribute — including a numeric calculation returning a number rather than a string; verify the test fails against the pre-change implementation with `UndefinedFunctionError` on `add_calculation/4` and passes with the change.

- [x] 2.7 Implement sorting by an expression calculation — project the calculation into the select list and order by its alias rather than passing the calculation struct to `Identifier.quote_name/1` — and report `:expression_calculation_sort` as supported; verify a unit case asserts the rendered `ORDER BY` references the alias, and an action-level case asserts the returned records are ordered by the calculated value.

## 3. Aggregate correctness

- [x] 3.1 Move the aggregate list out of `context[:aggregates]` and into the dedicated `aggregates` field on `%AshClickhouse.Query{}` that the struct already declares but never uses, updating `run_query/2`, `stream/3`, `run_aggregate_query/3`, `add_aggregate/3`, and `add_aggregates/3` to read and write the field; verify `mix compile --warnings-as-errors` is clean and the existing aggregate unit tests still pass.

- [x] 3.2 De-duplicate the aggregate list by name in `add_aggregate/3` and `add_aggregates/3`, so Ash's two calls to `add_aggregates/3` with the same list produce one set of aggregates; verify a unit case asserts the aggregate list holds one entry per name after both callbacks have run.

- [x] 3.3 Add a query-counting fake to the test support so the number of ClickHouse queries issued is observable, and add a test asserting a read loading N relationship aggregates issues exactly N aggregate queries rather than 2N; verify the test fails against the pre-change implementation and passes with the change.

- [x] 3.4 Merge the aggregate's own `query.filter` into the aggregate's `WHERE` clause in `Aggregate.run/6` and `batched_related/7`, translating it against the aggregated resource rather than the source resource, and preserving the UUID parameter conversion for the filter's own parameters; verify an action-level test asserts a count aggregate with a filter counts only the matching rows and differs from an unfiltered count over the same rows.

- [x] 3.5 Merge the aggregate's own `query.sort` into the aggregate query's `ORDER BY` for the kinds whose value depends on row order; verify an action-level test asserts a first aggregate with a descending sort returns the greatest matching value and that the sort direction is honoured.

- [x] 3.6 Apply the aggregate's `join_filters` by combining each path's filter into the aggregate's `WHERE` clause; verify a unit case asserts the combined `WHERE` clause contains the join filter's predicate alongside the aggregate's own.

- [x] 3.7 Assert that a filtered aggregate over no matching rows yields zero rather than null or absent, and that a first aggregate over no matching rows yields the aggregate's declared default; verify both cases as unit assertions on the decoded aggregate value.

## 4. Additional aggregate kinds

- [x] 4.1 Implement the `:first` aggregate kind in `AshClickhouse.DataLayer.Aggregate` — `ORDER BY <sort> LIMIT 1` — reusing the existing batched same-table and relationship paths so the one-query-per-aggregate batching applies; verify a unit case asserts the rendered aggregate query and a unit case asserts the decoded value.

- [x] 4.2 Implement the `:list` aggregate kind, collecting the matching rows' field values and ordering them by the aggregate's sort when one is declared; verify a unit case asserts the decoded value carries every matching row's field value in the sorted order.

- [x] 4.3 Implement the `:exists` aggregate kind, reporting whether any row matched the aggregate's filter; verify a unit case asserts the value is true when a row matched and false when none did.

- [x] 4.4 Report `{:aggregate, kind}` support for `:first`, `:list`, and `:exists`, and `{:query_aggregate, kind}` support for the same three, in `can?/2`; verify a unit case asserts each answer, and that an unsupported kind still reports `false`.

- [x] 4.5 Add an action-level test loading each of the three new aggregate kinds over a relationship and asserting each record carries the expected value, that a record with no related rows carries the declared default, and that the whole read issues one query per aggregate; verify the cases pass.

## 5. Relationship queries

- [x] 5.1 Implement the semi-join translation for a filter whose reference carries a non-empty `relationship_path`: resolve the path via `Ash.Resource.Info.relationship/2` to find the join key on each side, and render the outer predicate as a membership test against a subquery over the related table, preserving the UUID parameter conversion for both the join key and the inner predicate's parameters; verify a unit case asserts the rendered `WHERE` clause contains the membership test and the subquery.

- [x] 5.2 Report `can?({:filter_relationship, relationship})` as `true`, and refuse at build time — by reporting `false` for the multi-hop paths the layer cannot express — so an inexpressible relationship filter is rejected when the query is built rather than failing during execution; verify a unit case asserts the single-hop answer is `true` and the multi-hop answer is `false`.

- [x] 5.3 Report `can?({:aggregate_relationship, relationship})` as `true` so a resource declaring an aggregate over a relationship compiles; verify by adding a test resource with a relationship aggregate and asserting it compiles without the "is not aggregatable" DSL error, and that an action-level read loads the aggregate onto each record.

- [x] 5.4 Implement the unrelated existence check — `%Ash.Query.Exists{related?: false, resource: r, expr: e}` → `EXISTS (SELECT 1 FROM <r's table> WHERE <e>)`, translating the inner expression against `r` — and report `can?({:exists, :unrelated})` as `true`; verify a unit case asserts the rendered `WHERE` clause and an action-level test asserts the query returns the expected rows.

- [x] 5.5 Add action-level tests proving a filter across a relationship returns the queried rows with a matching related row, excludes rows whose related rows all fail, returns a matching row exactly once however many related rows match, and combines with the query's own filter; verify each case passes and that the returned row count equals the number of queried rows with a match.

## 6. Combination queries

- [x] 6.1 Extend `%AshClickhouse.Query{}` to hold the combination parts, and implement `combination_of/3` to render each part's statement and combine them into the union forms the layer supports; verify a unit case asserts the rendered statement combines the parts with the expected set operator.

- [x] 6.2 Implement `combination_acc/1` to return the accumulated parts so a subsequent part can be appended, keeping the parts in the order Ash supplied them; verify a unit case asserts the accumulator's contents and their order.

- [x] 6.3 Report `can?(:combine)` and `can?({:combine, :union_all})` as `true`, and keep the unsupported combination kinds reported as `false` so a query using one is refused before it is issued; verify a unit case asserts each answer.

- [x] 6.4 Add action-level tests proving a union query completes, returns each part's rows, keeps duplicate rows for the concatenating union and drops them for the deduplicating union, preserves each part's own filter, limit, and sort, and issues one statement to the database for the combined read; verify each case passes and that the fake repo records a single query.

- [x] 6.5 Correct the moduledoc in `lib/ash_clickhouse/data_layer.ex` and the table in `guides/limitations.md`, which claim combination queries are "executed by Ash in memory" — a fallback that does not exist in Ash 3.33 — so the text matches the delivered behaviour; verify by reading both files and confirming no claim of an in-memory fallback remains.

## 7. Query options

- [x] 7.1 Implement `distinct_sort/3` in `lib/ash_clickhouse/data_layer.ex`, storing the sort on the query, and render a distinct-sorted query as `GROUP BY <distinct cols> ... ORDER BY <distinct sort> LIMIT 1 BY <distinct cols>`; verify a unit case asserts the rendered statement carries the `GROUP BY` and `LIMIT 1 BY` clauses and that the requested sort drives the `ORDER BY`.

- [x] 7.2 Report `can?(:distinct_sort)` as `true`; verify a unit case asserts the answer, and an action-level test asserts a distinct-sorted query is valid, returns one record per distinct value, and selects the record that comes first under the requested sort — including under a descending sort.

- [x] 7.3 Report `can?(:timeout)` as `true` and thread the query's timeout into the request's `settings:` map as `max_execution_time`, in seconds and rounded up, merged with the existing `mutations_sync` setting; verify a unit case asserts the settings map carries the converted value and that the `mutations_sync` setting is preserved when both are present.

- [x] 7.4 Read the timeout from the query context, where Ash threads it (`query.ex:4530-4539`), rather than from the `Ash.Query` struct, since the data-layer query is built separately; verify an action-level test asserts a query with a timeout carries the setting on the request, and that a query whose timeout elapses fails with a timeout error rather than returning a result.

- [x] 7.5 Implement `default_bulk_batch_size/2` returning the layer's existing batch-size constant, so Ash's own chunking matches the layer's internal insert batching instead of Ash's default of 100 overriding it; verify a unit case asserts the reported size, and an action-level test asserts a bulk write of more rows than the reported size sends the rows in groups of that size, while an explicit caller-specified batch size still takes precedence.

## 8. Integration checks and release bookkeeping

- [x] 8.1 Run the full unit suite and `mix format --check-formatted` over the project's formatter inputs, and verify there are no new failures and no formatting diff in the tracked source files.

- [x] 8.2 Run `mix credo --strict` and `mix dialyzer`, and verify both report no new issues introduced by the change.

- [x] 8.3 Update the feature tables in `README.md` and `guides/limitations.md` so the supported and unsupported feature lists match the new `can?/2` answers — including the newly supported relationship filters, unrelated existence checks, distinct sorting, query timeouts, combination queries, the additional aggregate kinds, and the removal of the relationship-aggregate compile-time rejection; verify by reading each entry against the corresponding `can?/2` clause.

- [x] 8.4 Bump the version in `mix.exs` and add a `CHANGELOG.md` entry naming each user-visible symptom this change removes — the `UndefinedFunctionError` on reading a resource with an expression calculation, the `MatchError` from the mis-shaped `calculate/3`, the `QueryError` on `!=` and function-shaped filters, the wrong counts from filtered aggregates, the compile-time rejection of relationship aggregates, the hard errors from `distinct_sort` and `timeout`, and the doubled aggregate queries; verify the entry lists each symptom by name.

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
