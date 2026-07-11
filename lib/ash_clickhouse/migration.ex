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

    index_defs = Enum.map(Dsl.indexes(resource), &index_definition_cql/1)

    columns_and_indexes = Enum.join(columns ++ index_defs, ",\n  ")

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
      "  #{columns_and_indexes}",
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

  defp index_definition_cql(%{
         name: name,
         expression: expression,
         type: type,
         granularity: granularity
       }) do
    "INDEX #{Identifier.quote_name(name)} (#{expression}) TYPE #{type} GRANULARITY #{granularity}"
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
      type -> inspect_numeric_default(value, type)
    end
  end

  # Numeric/other column types expect a bare literal (e.g. `42`, `1.5`). A
  # developer-authored default that is not a number would otherwise be passed
  # through `to_string/1` unescaped and could corrupt the generated DDL, so we
  # validate it is numeric before emitting it.
  defp inspect_numeric_default(value, _type) when is_integer(value), do: to_string(value)
  defp inspect_numeric_default(value, _type) when is_float(value), do: to_string(value)

  defp inspect_numeric_default(value, type) when is_binary(value) do
    case Float.parse(value) do
      {_num, ""} ->
        value

      _ ->
        raise AshClickhouse.Error.ConfigurationError, """
        Non-numeric default #{inspect(value)} is not valid for column type #{type}.
        Defaults for numeric columns must be numbers.
        """
    end
  end

  defp inspect_numeric_default(value, type) do
    raise AshClickhouse.Error.ConfigurationError, """
    Non-numeric default #{inspect(value)} is not valid for column type #{type}.
    Defaults for numeric columns must be numbers.
    """
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
          |> Enum.map_join(", ", &Identifier.quote_name/1)

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
  Generates `ALTER TABLE ... ADD INDEX IF NOT EXISTS` statements for indexes
  configured on the resource but not yet present in ClickHouse, and detects
  configured indexes whose *definition* differs from what's actually stored.

  Returns `{statements, warnings}`:

    * `statements` — safe, additive `ADD INDEX IF NOT EXISTS` statements for
      indexes that don't exist yet.
    * `warnings` — human-readable strings for indexes that exist under the
      same name but with a different `type` or `expression` than configured.
      These are **not** auto-corrected: ClickHouse requires `DROP INDEX` +
      `ADD INDEX` to change a data-skipping index in place, and doing that
      automatically risks silently discarding a built index on a large table
      without the operator's knowledge. The warning tells you what to run
      manually.

  Comparison of `expression` is best-effort: ClickHouse normalizes stored
  expressions (whitespace, sometimes backtick quoting, occasionally constant
  folding) so it may not match your DSL string byte-for-byte even when they're
  semantically identical. When in doubt, treat a `type` mismatch as
  authoritative and double-check `expression` mismatches by hand before acting
  on them.
  """
  @spec alter_indexes_cql(module(), module()) :: {[String.t()], [String.t()]}
  def alter_indexes_cql(resource, repo) do
    configured = Dsl.indexes(resource)

    if configured == [] do
      {[], []}
    else
      table_name = AshClickhouse.DataLayer.source(resource)
      table = Identifier.quote_name(table_name)
      database = Dsl.database(resource)

      qualified =
        case database do
          nil -> table
          db -> "#{Identifier.quote_name(db)}.#{table}"
        end

      existing = fetch_existing_indexes(repo, table_name, database)

      {to_add, to_check} =
        Enum.split_with(configured, fn idx -> not Map.has_key?(existing, to_string(idx.name)) end)

      statements =
        Enum.map(to_add, fn idx ->
          "ALTER TABLE #{qualified} ADD INDEX IF NOT EXISTS #{index_definition_cql(idx)}"
        end)

      warnings =
        to_check
        |> Enum.map(fn idx ->
          index_mismatch_warning(idx, Map.fetch!(existing, to_string(idx.name)), qualified)
        end)
        |> Enum.reject(&is_nil/1)

      {statements, warnings}
    end
  end

  # Returns %{"index_name" => %{type: "...", expression: "..."}} for indexes
  # currently present on the table, or %{} if the lookup fails (e.g. system
  # table unavailable / permissions) — in which case we fall back to treating
  # every configured index as "unknown", same degrade-gracefully behavior as
  # `alter_table_cql/2` uses for columns.
  defp fetch_existing_indexes(repo, table_name, database) do
    case repo.query(
           "SELECT name, type, expr FROM system.data_skipping_indices WHERE table = ? AND database = ?",
           [table_name, database || repo.database() || "default"]
         ) do
      {:ok, %ClickHouse.Result{rows: rows}} ->
        Map.new(rows, fn [name, type, expr] ->
          {name, %{type: type, expression: expr}}
        end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp index_mismatch_warning(
         configured,
         %{type: stored_type, expression: stored_expr},
         qualified
       ) do
    type_mismatch? = normalize(configured.type) != normalize(stored_type)
    expr_mismatch? = normalize(configured.expression) != normalize(stored_expr)

    cond do
      type_mismatch? and expr_mismatch? ->
        """
        Index #{inspect(configured.name)} on #{qualified} differs from its configuration in BOTH type and expression:
          configured: TYPE #{configured.type} (#{configured.expression})
          stored:     TYPE #{stored_type} (#{stored_expr})
        To apply the configured definition, run manually:
          ALTER TABLE #{qualified} DROP INDEX #{Identifier.quote_name(configured.name)};
          ALTER TABLE #{qualified} ADD INDEX #{index_definition_cql(configured)};
        """

      type_mismatch? ->
        """
        Index #{inspect(configured.name)} on #{qualified} has type #{inspect(stored_type)} in ClickHouse \
        but is configured as #{inspect(configured.type)}. Not auto-corrected — run manually:
          ALTER TABLE #{qualified} DROP INDEX #{Identifier.quote_name(configured.name)};
          ALTER TABLE #{qualified} ADD INDEX #{index_definition_cql(configured)};
        """

      expr_mismatch? ->
        """
        Index #{inspect(configured.name)} on #{qualified} has expression #{inspect(stored_expr)} in ClickHouse \
        but is configured as #{inspect(configured.expression)}. This may be a harmless normalization \
        difference (whitespace/quoting) rather than a real mismatch — verify before acting. If it's real:
          ALTER TABLE #{qualified} DROP INDEX #{Identifier.quote_name(configured.name)};
          ALTER TABLE #{qualified} ADD INDEX #{index_definition_cql(configured)};
        """

      true ->
        nil
    end
  end

  # Loose normalization so whitespace/case differences between the DSL string
  # and ClickHouse's stored/echoed form don't produce false-positive warnings.
  defp normalize(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.replace(~r/\s+/, "")
    |> String.trim()
  end

  defp normalize(other), do: other

  @doc """
  Generates all migration statements (table creation) for a list of resources.
  """
  @spec generate_resource_cql(module()) :: [String.t()]
  def generate_resource_cql(resource) do
    [create_table_cql(resource)]
  end
end
