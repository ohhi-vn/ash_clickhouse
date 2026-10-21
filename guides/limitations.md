# Limitations

Because ClickHouse is a columnar OLAP store (not a transactional RDBMS), some
Ash features are intentionally unsupported. The data layer reports these via
`can?/2` so Ash can fail fast or fall back appropriately.

## Not supported

| Feature | Why |
| --- | --- |
| `:transact` | ClickHouse has no multi-statement transactions |
| `:lock` | Locking is a no-op (and reported unsupported) |
| `:keyset` | ClickHouse has no token-based keyset pagination — use `offset`/`limit` |
| `:upsert` | ClickHouse has no `ON CONFLICT` — use `create` + `update_query` |
| `:join` | A full join is not implemented — relationship filters are answered with a semi-join instead |
| `{:combine, :except \| :intersect}` | Only the union kinds are supported |
| `:aggregate_filter` / `:aggregate_sort` | The per-aggregate `filter:` and `sort:` options are applied instead |
| `:update_many` | Use `:update_query` instead |
| `:composite_type` / `:through_relationship` | Not supported |
| `:bulk_create_with_partial_success` | Not supported |
| `:bulk_upsert_return_skipped` | Not supported |
| `{:query_aggregate, :custom}` | Custom aggregates are not implemented |
| `{:atomic, _}` | Not supported |

A relationship filter is only supported for a **single-hop** relationship path.
A filter that reaches across more than one relationship is refused when the
query is built, rather than failing while the query runs.

## Supported

- CRUD (`create`, `read`, `update`, `destroy`)
- `filter`, `sort`, `limit`, `offset`, `select`, `distinct`, `distinct_sort`
- `timeout` (mapped onto ClickHouse's `max_execution_time` setting)
- `bulk_create` (batched `INSERT`)
- `update_query` / `destroy_query` (`ALTER TABLE ... UPDATE/DELETE`)
- Native aggregates `count`, `sum`, `avg`, `min`, `max`, `first`, `list`, `exists`
- Aggregates over a relationship (`{:aggregate_relationship, _}`), computed with
  one grouped query for the whole result set
- Filters over a relationship (`{:filter_relationship, _}`), answered with a
  semi-join
- Existence checks over an unrelated resource (`{:exists, :unrelated}`)
- Combination queries — run as a single `UNION` statement
- `multitenancy` (attribute- or context-based)
- `calculate`, `composite_primary_key`, `nested_expressions`, `boolean_filter`
- `stream`, `changeset_filter`, `action_select`, `expression_calculation`,
  `expression_calculation_sort`
- `functions/1` — the layer publishes the ClickHouse functions usable in
  filters (`match/2` today)
- `async_engine`

## Workarounds

- **Upsert:** `Ash.create/2` then `Ash.update_query!/3` (or `ALTER TABLE ...
  UPDATE`).
- **Transactions:** batch work in a single mutation/insert; accept eventual
  consistency for `ALTER` mutations (control with `mutations_sync`).
- **Pagination:** use `offset`/`limit` instead of keyset.
- **Joins / relationships:** relationships are read with a separate query and a
  semi-join for filters; model denormalized tables when a report needs the
  joined shape in one pass.

## Errors

Failures from the ClickHouse client are wrapped in
`AshClickhouse.Error.ClickhouseError`, which carries `:message`, `:query`,
`:params`, and `:reason`. This keeps Ash error presentation consistent.
