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
  alias AshClickhouse.Error
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
      |> Enum.map(&column_definition(&1, resource))
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

  defp column_definition(attr, resource) do
    name = Identifier.quote_name(attr.name)
    base_type = Types.resolve_attr_type(attr)
    type = wrap_nullable(base_type, attr, resource)
    default = column_default(attr)
    "#{name} #{type}#{default}"
  end

  # ClickHouse expresses nullability by wrapping the *type* in Nullable(...),
  # not with a trailing NULL/NOT NULL qualifier. Composite inner types
  # (Array/Map/Tuple) cannot be wrapped in Nullable at all, so we reject that
  # combination with a clear error instead of emitting invalid DDL.
  defp wrap_nullable(type, attr, resource) do
    if attr.allow_nil? do
      if composite_type?(type) do
        raise Error.ConfigurationError, """
        ClickHouse does not support Nullable(#{type}) because the inner type is a
        composite type (Array/Map/Tuple), which cannot be wrapped in Nullable.

        On resource #{inspect(resource)}, attribute `#{attr.name}` is configured
        with `allow_nil?: true` and a composite type. Either set
        `allow_nil?: false` for this attribute, or model the nullability inside
        the collection (e.g. `Array(Nullable(String))`).
        """
      else
        "Nullable(#{type})"
      end
    else
      type
    end
  end

  defp composite_type?(type) do
    String.starts_with?(type, ["Array", "Map", "Tuple"])
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
      "String" -> "'#{escape_default(value)}'"
      "UUID" -> "'#{escape_default(value)}'"
      _ -> to_string(value)
    end
  end

  # Escape embedded quotes/backslashes in developer-supplied default literals
  # so they cannot break the generated DDL.
  defp escape_default(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
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
  Generates `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements for attributes
  that exist on the resource but not yet in the table. This is a minimal schema
  evolution pass: it adds new columns but does not drop or alter existing ones.

  Returns an empty list when the table does not exist yet (the CREATE TABLE
  statement handles initial creation) or when there are no new columns.
  """
  @spec alter_table_cql(module(), module()) :: [String.t()]
  def alter_table_cql(resource, repo) do
    table = Identifier.quote_name(AshClickhouse.DataLayer.source(resource))
    database = Dsl.database(resource)

    qualified =
      case database do
        nil -> table
        db -> "#{Identifier.quote_name(db)}.#{table}"
      end

    existing =
      case repo.query("SELECT name FROM system.columns WHERE table = ? AND database = ?", [
             AshClickhouse.DataLayer.source(resource),
             database || repo.database() || "default"
           ]) do
        {:ok, %ClickHouse.Result{rows: rows}} ->
          Enum.map(rows, fn [name] -> name end) |> MapSet.new()

        _ ->
          MapSet.new()
      end

    resource
    |> Info.attributes()
    |> Enum.reject(fn attr -> MapSet.member?(existing, to_string(attr.name)) end)
    |> Enum.map(fn attr ->
      type = wrap_nullable(Types.resolve_attr_type(attr), attr, resource)

      "ALTER TABLE #{qualified} ADD COLUMN IF NOT EXISTS #{Identifier.quote_name(attr.name)} #{type}"
    end)
  end

  @doc """
  Generates all migration statements (table creation) for a list of resources.
  """
  @spec generate_resource_cql(module()) :: [String.t()]
  def generate_resource_cql(resource) do
    [create_table_cql(resource)]
  end
end
