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
| `:join` | JOINs are not yet implemented |
| `:combine` (UNION/INTERSECT) | Not yet implemented (Ash can do it in memory) |
| `:filter_relationship` | Not yet implemented |
| `{:exists, :unrelated}` | Not yet implemented |
| `{:aggregate_relationship, _}` | Not yet implemented |
| `:expression_calculation_sort` | Not supported |
| `:aggregate_filter` / `:aggregate_sort` | Not supported |
| `:update_many` | Use `:update_query` instead |
| `:composite_type` / `:through_relationship` | Not supported |
| `:bulk_create_with_partial_success` | Not supported |
| `:bulk_upsert_return_skipped` | Not supported |
| `{:query_aggregate, :list \| :first \| :exists \| :custom}` | Only `count`/`sum`/`avg`/`min`/`max` |
| `{:atomic, _}` | Not supported |

## Supported

- CRUD (`create`, `read`, `update`, `destroy`)
- `filter`, `sort`, `limit`, `offset`, `select`, `distinct`
- `bulk_create` (batched `INSERT`)
- `update_query` / `destroy_query` (`ALTER TABLE ... UPDATE/DELETE`)
- Native aggregates `count`, `sum`, `avg`, `min`, `max`
- `multitenancy` (database- or attribute-based)
- `calculate`, `composite_primary_key`, `nested_expressions`, `boolean_filter`
- `stream`, `changeset_filter`, `action_select`, `expression_calculation`
- `async_engine`

## Workarounds

- **Upsert:** `Ash.create/2` then `Ash.update_query!/3` (or `ALTER TABLE ...
  UPDATE`).
- **Transactions:** batch work in a single mutation/insert; accept eventual
  consistency for `ALTER` mutations (control with `mutations_sync`).
- **Pagination:** use `offset`/`limit` instead of keyset.
- **Joins / relationships:** not yet available — model denormalized tables or
  resolve relationships in your domain code for now.

## Errors

Failures from the ClickHouse client are wrapped in
`AshClickhouse.Error.ClickhouseError`, which carries `:message`, `:query`,
`:params`, and `:reason`. This keeps Ash error presentation consistent.
