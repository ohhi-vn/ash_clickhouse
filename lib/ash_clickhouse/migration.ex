defmodule AshClickhouse.Migration do
  @moduledoc """
  Generates ClickHouse `CREATE TABLE` statements from Ash resources.

  ClickHouse tables require an engine and an `ORDER BY` key. This module maps
  Ash primary keys and attributes to ClickHouse column definitions and produces
  a `CREATE TABLE IF NOT EXISTS` statement using the engine configured in the
  resource's `clickhouse` DSL block.
  """

  alias Ash.Resource.Info
  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.DataLayer.Types
  alias AshClickhouse.Identifier

  @doc """
  Generates the `CREATE TABLE` SQL for a resource.
  """
  @spec create_table_cql(module()) :: String.t()
  def create_table_cql(resource) do
    table = Identifier.quote_name(AshClickhouse.DataLayer.source(resource))
    database = Dsl.database(resource)

    qualified =
      case database do
        nil -> table
        db -> "#{Identifier.quote_name(db)}.#{table}"
      end

    columns =
      resource
      |> Info.attributes()
      |> Enum.map(&column_definition/1)
      |> Enum.join(",\n  ")

    order_by = resolve_order_by(resource)
    partition_by = Dsl.partition_by(resource)
    primary_key = Dsl.primary_key(resource)
    engine = Dsl.engine(resource)
    settings = Dsl.settings(resource)

    order_clause = "ORDER BY (#{order_by})"

    pk_clause =
      if primary_key && primary_key != [] do
        "PRIMARY KEY (#{Enum.map_join(primary_key, ", ", &Identifier.quote_name/1)})"
      else
        ""
      end

    partition_clause =
      if partition_by do
        "PARTITION BY #{partition_by}"
      else
        ""
      end

    settings_clause =
      if settings do
        "SETTINGS #{settings}"
      else
        ""
      end

    parts = [
      "CREATE TABLE IF NOT EXISTS #{qualified} (",
      "  #{columns}",
      ")",
      "ENGINE = #{engine}",
      partition_clause,
      order_clause,
      pk_clause,
      settings_clause
    ]

    parts
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp column_definition(attr) do
    name = Identifier.quote_name(attr.name)
    type = Types.resolve_attr_type(attr)
    nullable = if attr.allow_nil?, do: "NULL", else: "NOT NULL"
    default = column_default(attr)
    "#{name} #{type} #{nullable}#{default}"
  end

  defp column_default(attr) do
    case Map.get(attr, :default) do
      nil -> ""
      value when is_function(value) -> ""
      value -> " DEFAULT #{inspect_default(value, attr)}"
    end
  end

  defp inspect_default(value, attr) do
    case Types.resolve_attr_type(attr) do
      "String" -> "'#{value}'"
      "UUID" -> "'#{value}'"
      _ -> to_string(value)
    end
  end

  defp resolve_order_by(resource) do
    case Dsl.order_by(resource) do
      nil ->
        pkey =
          resource
          |> Info.primary_key()
          |> Enum.map(&Identifier.quote_name/1)
          |> Enum.join(", ")

        if pkey == "", do: "tuple()", else: pkey

      order_by ->
        order_by
    end
  end

  @doc """
  Generates all migration statements (table creation) for a list of resources.
  """
  @spec generate_resource_cql(module()) :: [String.t()]
  def generate_resource_cql(resource) do
    [create_table_cql(resource)]
  end
end
