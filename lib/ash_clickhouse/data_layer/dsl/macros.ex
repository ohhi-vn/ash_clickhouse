defmodule AshClickhouse.DataLayer.Dsl.Macros do
  @moduledoc """
  Compile-time macros for the ClickHouse DSL.

  This module only contains the `clickhouse/1` macro (and its private helpers).
  It is intentionally kept separate from `AshClickhouse.DataLayer.Dsl` so that
  importing it does not also import the runtime getter functions (such as
  `table/1`). That separation matters: a resource may define a local helper
  macro or function named like a DSL key (e.g. `table/1`) inside a `clickhouse`
  block value, and we must not shadow it with an imported getter.
  """

  @doc """
  Macro for configuring ClickHouse options in Ash resources.

  Import this module (and only this module) to use the `clickhouse` block:

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table "my_table"
        repo MyApp.Repo
      end

  The runtime getters (e.g. `AshClickhouse.DataLayer.Dsl.table/1`) live in
  `AshClickhouse.DataLayer.Dsl` and are not imported by this module.
  """
  @spec clickhouse(keyword()) :: Macro.t()
  defmacro clickhouse(do: block) do
    statements =
      case block do
        {:__block__, _, stmts} -> stmts
        stmt -> [stmt]
      end

    transformed =
      Enum.map(statements, fn
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

        {:insert_opts, meta, [value]} ->
          set(meta, :__set_insert_opts__, value)

        {:mutations_sync, meta, [value]} ->
          set(meta, :__set_mutations_sync__, value)

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
      @ash_clickhouse_insert_opts []
      @ash_clickhouse_mutations_sync nil

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
        migrate: @ash_clickhouse_migrate,
        insert_opts: @ash_clickhouse_insert_opts,
        mutations_sync: @ash_clickhouse_mutations_sync
      }

      def __ash_clickhouse__(key), do: Map.get(@ash_clickhouse_config, key)
    end
  end

  defp set(meta, fun, value) do
    {{:., meta, [{:__aliases__, meta, [:AshClickhouse, :DataLayer, :Dsl, :Macros]}, fun]}, meta,
     [{:__MODULE__, [], nil}, value]}
  end

  # --- setters (called at compile time) ------------------------------------

  @doc false
  def __set_table__(module, value), do: Module.put_attribute(module, :ash_clickhouse_table, value)

  @doc false
  def __set_repo__(module, value), do: Module.put_attribute(module, :ash_clickhouse_repo, value)

  @doc false
  def __set_database__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_database, value)

  @doc false
  def __set_engine__(module, value),
    do: Module.put_attribute(module, :ash_clickhouse_engine, value)

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

  @doc false
  def __set_insert_opts__(module, value) when is_list(value),
    do: Module.put_attribute(module, :ash_clickhouse_insert_opts, value)

  @doc false
  def __set_mutations_sync__(module, value) when value in [nil, 1, 2],
    do: Module.put_attribute(module, :ash_clickhouse_mutations_sync, value)
end
