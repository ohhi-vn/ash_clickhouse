defmodule AshClickhouse.DataLayer.Dsl do
  @moduledoc """
  Runtime accessors for ClickHouse-specific options configured on Ash resources.

  These functions read the configuration produced by the `clickhouse` DSL block
  (see `AshClickhouse.DataLayer.Dsl.Macros`). They are intentionally kept in a
  separate module from the `clickhouse` macro so that importing the macro module
  does not also import these getters — that separation lets a resource define a
  local helper named like a DSL key (e.g. `table/1`) without it being shadowed
  by an imported getter.

  ## Usage

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table "my_table"
          repo MyApp.Repo
          database "my_app_dev"

          base_filter [status: "active"]
          default_context %{tenant: "org_123"}
          description "My resource description"

          engine "MergeTree()"
          order_by "id"
          partition_by "toYYYYMM(inserted_at)"

          settings "index_granularity = 8192"
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end
      end

  ## Options

  - `:table` — the table name in ClickHouse (overrides the default)
  - `:repo` — the `AshClickhouse.Repo` module to use
  - `:database` — the database to use (overrides repo default)
  - `:engine` — the ClickHouse table engine (default `"MergeTree()"`)
  - `:order_by` — `ORDER BY` expression for the table engine
  - `:partition_by` — `PARTITION BY` expression for the table engine
  - `:primary_key` — explicit primary key columns (ClickHouse `PRIMARY KEY`)
  - `:settings` — engine settings string
  - `:base_filter` — a filter applied to all queries on this resource
  - `:default_context` — context merged into every query/changeset
  - `:description` — human-readable description of the resource
  - `:migrate` — whether this resource is included in migrations (default `true`)
  - `:insert_opts` — options applied to bulk inserts (e.g. `async_insert: 1`)
  - `:mutations_sync` — default `mutations_sync` for ALTER mutations (`1`/`2`/`nil`)
  - `:index` — repeated; declares a data-skipping index (see `clickhouse do ... end`)
  """

  # --- getters -------------------------------------------------------------

  defp get_config(resource, key, default \\ nil) do
    if function_exported?(resource, :__ash_clickhouse__, 1) do
      resource.__ash_clickhouse__(key)
    else
      default
    end
  end

  @doc "Whether this resource is included in migrations (default `true`)."
  @spec migrate?(module()) :: boolean()
  def migrate?(resource), do: get_config(resource, :migrate, true)

  @doc """
  Options applied to bulk inserts for this resource (e.g.
  `async_insert: 1, wait_for_async_insert: 1`).
  """
  @spec insert_opts(module()) :: keyword()
  def insert_opts(resource), do: get_config(resource, :insert_opts, [])

  @doc """
  The default `mutations_sync` value for ALTER TABLE mutations on this resource
  (1 = wait on current replica, 2 = wait on all replicas, nil = async).
  """
  @spec mutations_sync(module()) :: nil | 1 | 2
  def mutations_sync(resource), do: get_config(resource, :mutations_sync)

  @doc "The configured table name."
  @spec table(module()) :: String.t() | nil
  def table(resource), do: get_config(resource, :table)

  @doc "The configured repo module."
  @spec repo(module()) :: module() | nil
  def repo(resource), do: get_config(resource, :repo)

  @doc "The configured database (overrides repo default)."
  @spec database(module()) :: String.t() | nil
  def database(resource), do: get_config(resource, :database)

  @doc "The configured table engine."
  @spec engine(module()) :: String.t()
  def engine(resource), do: get_config(resource, :engine, "MergeTree()")

  @doc "The configured ORDER BY expression."
  @spec order_by(module()) :: String.t() | nil
  def order_by(resource), do: get_config(resource, :order_by)

  @doc "The configured PARTITION BY expression."
  @spec partition_by(module()) :: String.t() | nil
  def partition_by(resource), do: get_config(resource, :partition_by)

  @doc "The configured explicit PRIMARY KEY columns."
  @spec primary_key(module()) :: list(atom()) | nil
  def primary_key(resource), do: get_config(resource, :primary_key)

  @doc "The configured engine settings string."
  @spec settings(module()) :: String.t() | nil
  def settings(resource), do: get_config(resource, :settings)

  @doc "The configured base_filter."
  @spec base_filter(module()) :: term() | nil
  def base_filter(resource), do: get_config(resource, :base_filter)

  @doc "The configured default_context."
  @spec default_context(module()) :: map() | nil
  def default_context(resource), do: get_config(resource, :default_context)

  @doc "The configured data-skipping indexes."
  @spec indexes(module()) :: [map()]
  def indexes(resource), do: get_config(resource, :indexes, [])

  @doc "The configured description."
  @spec description(module()) :: String.t() | nil
  def description(resource), do: get_config(resource, :description)
end
