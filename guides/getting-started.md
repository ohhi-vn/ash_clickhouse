# Getting Started

This guide walks you through installing AshClickhouse and running your first
resource against a ClickHouse database.

AshClickhouse is an [Ash Framework](https://ash-hq.org) data layer for
[ClickHouse](https://clickhouse.com). It implements the `Ash.DataLayer`
behaviour using the [`clickhouse`](https://hex.pm/packages/clickhouse) client.

> **Note:** This library is under active development, unstable, and the API may
> change.

## Prerequisites

- Elixir `~> 1.17`
- A reachable ClickHouse server (default `http://localhost:8123`)
- An Ash application (domain + resources)

## Installation

Add the dependency to `mix.exs`:

```elixir
def deps do
  [
    {:ash, "~> 3.0"},
    {:ash_clickhouse, "~> 0.2.0"}
  ]
end
```

Then fetch it:

```sh
mix deps.get
```

## 1. Configure a Repo

A *Repo* holds the connection configuration for a ClickHouse database.

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use AshClickhouse.Repo, otp_app: :my_app
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  url: "http://localhost:8123",
  database: "my_app_dev"
```

## 2. Add the Repo to your supervision tree

```elixir
# lib/my_app/application.ex
children = [MyApp.Repo, ...]
```

## 3. Define a resource

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: MyApp.Domain

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table "users"
    repo MyApp.Repo
    engine "MergeTree()"
    order_by "id"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

Register it on a domain:

```elixir
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end
```

## 4. Create the database and tables

```sh
mix ash_clickhouse.setup    # CREATE DATABASE IF NOT EXISTS
mix ash_clickhouse.migrate  # CREATE TABLE IF NOT EXISTS ...
```

## 5. Use it

```elixir
{:ok, user} = Ash.create(MyApp.User, %{name: "John", email: "john@example.com"})
users = Ash.read!(MyApp.User)
```

## Next steps

- [Resources](resources.md) — the `clickhouse` DSL block in detail
- [Configuration](configuration.md) — all Repo and resource options
- [Migrations](migrations.md) — schema generation and evolution
- [Querying](querying.md) — filters, sorting, aggregates, bulk operations
- [Multitenancy](multitenancy.md) — database- and attribute-based tenants
- [Types](types.md) — Ash ↔ ClickHouse type mapping
- [Telemetry](telemetry.md) — observability
- [Limitations](limitations.md) — what is not supported and why
