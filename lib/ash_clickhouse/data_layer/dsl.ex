defmodule AshClickhouse.DataLayer.Dsl do
  @moduledoc """
  DSL extensions for configuring ClickHouse-specific options on Ash resources.

  ## Usage

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer

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
  """

  @doc """
  Macro for configuring ClickHouse options in Ash resources.
  """
  @spec clickhouse(keyword()) :: Macro.t()
  defmacro clickhouse(do: block) do
    transformed =
      Macro.prewalk(block, fn
        {:table, meta, [value]} ->
          set(meta, :__set_table__, value)

        {:repo, meta, [value]} ->
          set(meta, :__set_repo__, value)

        {:database, meta, [value]} ->
          set(meta, :__set_database__, value)

        {:engine, meta, [value]} ->
          set(meta, :__set_engine__, value)

        {:order_by, meta, [value]} ->
          set(meta, :__set_order_by__, value)

        {:partition_by, meta, [value]} ->
          set(meta, :__set_partition_by__, value)

        {:primary_key, meta, [value]} ->
          set(meta, :__set_primary_key__, value)

        {:settings, meta, [value]} ->
          set(meta, :__set_settings__, value)

        {:base_filter, meta, [value]} ->
          set(meta, :__set_base_filter__, value)

        {:default_context, meta, [value]} ->
          set(meta, :__set_default_context__, value)

        {:description, meta, [value]} ->
          set(meta, :__set_description__, value)

        {:migrate, meta, [value]} ->
          set(meta, :__set_migrate__, value)

        other ->
          other
      end)

    quote do
      @ash_clickhouse_table nil
      @ash_clickhouse_repo nil
      @ash_clickhouse_database nil
      @ash_clickhouse_engine "MergeTree()"
      @ash_clickhouse_order_by nil
      @ash_clickhouse_partition_by nil
      @ash_clickhouse_primary_key nil
      @ash_clickhouse_settings nil
      @ash_clickhouse_base_filter nil
      @ash_clickhouse_default_context nil
      @ash_clickhouse_description nil
      @ash_clickhouse_migrate true

      unquote(transformed)

      @ash_clickhouse_config %{
        table: @ash_clickhouse_table,
        repo: @ash_clickhouse_repo,
        database: @ash_clickhouse_database,
        engine: @ash_clickhouse_engine,
        order_by: @ash_clickhouse_order_by,
        partition_by: @ash_clickhouse_partition_by,
        primary_key: @ash_clickhouse_primary_key,
        settings: @ash_clickhouse_settings,
        base_filter: @ash_clickhouse_base_filter,
        default_context: @ash_clickhouse_default_context,
        description: @ash_clickhouse_description,
        migrate: @ash_clickhouse_migrate
      }

      def __ash_clickhouse__(key), do: Map.get(@ash_clickhouse_config, key)
    end
  end

  defp set(meta, fun, value) do
    {{:., meta, [{:__aliases__, meta, [:AshClickhouse, :DataLayer, :Dsl]}, fun]}, meta,
     [{:__MODULE__, [], nil}, value]}
  end

  # --- getters -------------------------------------------------------------

  defp get_config(resource, key, default \\ nil) do
    if function_exported?(resource, :__ash_clickhouse__, 1) do
      try do
        resource.__ash_clickhouse__(key)
      rescue
        FunctionClauseError -> default
      end
    else
      default
    end
  end

  @doc "Whether this resource is included in migrations (default `true`)."
  @spec migrate?(module()) :: boolean()
  def migrate?(resource), do: get_config(resource, :migrate, true)

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

  @doc "The configured description."
  @spec description(module()) :: String.t() | nil
  def description(resource), do: get_config(resource, :description)

  # --- setters (called at compile time) ------------------------------------

  @doc false
  def __set_table__(module, value), do: Module.put_attribute(module, :ash_clickhouse_table, value)

  @doc false
  def __set_repo__(module, value), do: Module.put_attribute(module, :ash_clickhouse_repo, value)

  @doc false
  def __set_database__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_database, value)

  @doc false
  def __set_engine__(module, value), do: Module.put_attribute(module, :ash_clickhouse_engine, value)

  @doc false
  def __set_order_by__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_order_by, value)

  @doc false
  def __set_partition_by__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_partition_by, value)

  @doc false
  def __set_primary_key__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_primary_key, value)

  @doc false
  def __set_settings__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_settings, value)

  @doc false
  def __set_base_filter__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_base_filter, value)

  @doc false
  def __set_default_context__(module, value) when is_map(value),
    do: Module.put_attribute(module, :ash_clickhouse_default_context, value)

  @doc false
  def __set_description__(module, value) when is_binary(value),
    do: Module.put_attribute(module, :ash_clickhouse_description, value)

  @doc false
  def __set_migrate__(module, value) when is_boolean(value),
    do: Module.put_attribute(module, :ash_clickhouse_migrate, value)
end
