# Multitenancy

AshClickhouse supports Ash's `multitenancy` feature. Two strategies are
available, configured on the resource via Ash's `multitenancy` DSL:

- **Database-based** — the tenant becomes part of the table qualifier
  (`"tenant_db"."table"`).
- **Attribute-based** — the tenant is applied as a filter on a tenant column.

Multitenancy is reported as supported by the data layer (`can?(:multitenancy)`).

## Enabling multitenancy

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: MyApp.Domain

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table "posts"
    repo MyApp.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :string
    attribute :title, :string
  end
end
```

## Setting the tenant

The data layer applies the tenant through `set_tenant/3`:

```elixir
MyApp.Post
|> Ash.Query.set_tenant("org_123")
|> Ash.read!()
```

For database-based multitenancy, the tenant is resolved into the qualified table
name at query time. For attribute-based multitenancy, a filter on the tenant
column is added to every query (and combined with any `base_filter`).

## Interaction with `base_filter` and `default_context`

- `base_filter` (resource DSL) is always applied on top of tenant scoping.
- `default_context` (resource DSL) is merged into every query/changeset, so you
  can seed tenant-like context there if needed.

## Notes

- ClickHouse has no row-level security; attribute-based multitenancy is enforced
  by the data layer adding filters, not by the database.
- Ensure the tenant column exists in your schema (it is a normal attribute).
