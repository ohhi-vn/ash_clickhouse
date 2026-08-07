# Multitenancy

AshClickhouse supports Ash's `multitenancy` feature, configured on the
resource via Ash's `multitenancy` DSL. The supported strategies are:

- **Attribute-based** — a tenant column on each row; the data layer adds an
  equality filter on that column to every query.
- **Context-based** — the tenant is stored on the query and read from the
  query/changeset context; use it to drive your own scoping.

Multitenancy is reported as supported by the data layer (`can?(:multitenancy)`).

## Attribute-based

The tenant is a normal attribute. The data layer injects a `tenant_id = ?`
filter into every query (combined with any `base_filter`):

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

## Context-based

The tenant is stored on the query and can be read back from its context. It is
your responsibility to turn it into scoping (e.g. via `base_filter` or
`default_context`):

```elixir
multitenancy do
  strategy :context
end
```

## Setting the tenant

The data layer applies the tenant through `set_tenant/3`:

```elixir
MyApp.Post
|> Ash.Query.set_tenant("org_123")
|> Ash.read!()
```

With the attribute strategy, this adds the tenant equality filter. With the
context strategy, the tenant is stored on the query (`query.tenant`) for the
rest of the pipeline.

## Interaction with `base_filter` and `default_context`

- `base_filter` (resource DSL) is always applied on top of tenant scoping.
- `default_context` (resource DSL) is merged into every query/changeset, so you
  can seed tenant-like context there if needed.

## Notes

- ClickHouse has no row-level security; attribute-based multitenancy is enforced
  by the data layer adding filters, not by the database.
- Ensure the tenant column exists in your schema (it is a normal attribute).
- There is no database-per-tenant feature: the table qualifier always comes
  from the resource's `database` / repo configuration, not from the tenant.
