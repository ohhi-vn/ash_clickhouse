defmodule AshClickhouse.DataLayer.QueryBuilder do
  @moduledoc """
  Builds ClickHouse SQL from an `AshClickhouse.Query` struct.

  ClickHouse is a full SQL dialect, so most Ash query features map directly:
  `WHERE`, `ORDER BY`, `LIMIT`, `OFFSET`, `SELECT`, `DISTINCT`, `GROUP BY`, and
  aggregate functions are all natively supported.
  """

  alias AshClickhouse.Identifier
  alias AshClickhouse.Query

  @doc """
  Builds the final SELECT query and parameter list.
  """
  @spec build_optimized_query(Query.t()) :: {String.t(), list()}
  def build_optimized_query(%Query{} = query) do
    %Query{
      table: table,
      database: database,
      filters: filters,
      sorts: sorts,
      limit: limit,
      offset: offset,
      select: select,
      distinct: distinct,
      group_by: group_by
    } = query

    qualified = qualified_table(table, database)

    {where_clause, where_params} = build_where_clause(filters)

    select_clause =
      case {distinct, select} do
        {cols, _} when is_list(cols) and cols != [] ->
          "DISTINCT " <> Enum.map_join(cols, ", ", &Identifier.quote_name/1)

        {_, cols} when is_list(cols) and cols != [] ->
          Enum.map_join(cols, ", ", &Identifier.quote_name/1)

        _ ->
          "*"
      end

    order_clause =
      if sorts == [] or is_nil(sorts) do
        ""
      else
        " ORDER BY " <>
          Enum.map_join(sorts, ", ", fn
            {field, :asc} -> "#{Identifier.quote_name(field)} ASC"
            {field, :desc} -> "#{Identifier.quote_name(field)} DESC"
            field when is_atom(field) -> "#{Identifier.quote_name(field)} ASC"
          end)
      end

    limit_clause = if limit, do: " LIMIT #{truncate_integer(limit)}", else: ""
    offset_clause = if offset, do: " OFFSET #{truncate_integer(offset)}", else: ""

    group_clause =
      if group_by && group_by != [] do
        " GROUP BY " <> Enum.map_join(group_by, ", ", &Identifier.quote_name/1)
      else
        ""
      end

    sql =
      IO.iodata_to_binary([
        "SELECT ",
        select_clause,
        " FROM ",
        qualified,
        where_clause,
        group_clause,
        order_clause,
        limit_clause,
        offset_clause
      ])

    {sql, where_params}
  end

  @doc """
  Builds a WHERE clause from a list of Ash filter expressions.

  Returns `{clause, params}` where `clause` is either `""` or
  `" WHERE <expr>"`.
  """
  @spec build_where_clause(list()) :: {String.t(), list()}
  def build_where_clause([]), do: {"", []}

  def build_where_clause(filters) when is_list(filters) do
    {parts, params} =
      Enum.reduce(filters, {[], []}, fn filter, {parts_acc, params_acc} ->
        case build_predicate(filter) do
          {sql, new_params} -> {[sql | parts_acc], new_params ++ params_acc}
          nil -> {parts_acc, params_acc}
        end
      end)

    case Enum.reverse(parts) do
      [] -> {"", []}
      parts -> {" WHERE " <> Enum.join(parts, " AND "), Enum.reverse(params)}
    end
  end

  # Builds a single predicate (SQL fragment + params) from an Ash filter expr.
  @spec build_predicate(term()) :: {String.t(), list()} | nil
  defp build_predicate(nil), do: nil

  defp build_predicate(%{op: :and, left: left, right: right}) do
    case {build_predicate(left), build_predicate(right)} do
      {{l_sql, l_p}, {r_sql, r_p}} ->
        {"(#{l_sql} AND #{r_sql})", l_p ++ r_p}

      {pred, nil} ->
        pred

      {nil, pred} ->
        pred
    end
  end

  defp build_predicate(%{op: :or, left: left, right: right}) do
    case {build_predicate(left), build_predicate(right)} do
      {{l_sql, l_p}, {r_sql, r_p}} ->
        {"(#{l_sql} OR #{r_sql})", l_p ++ r_p}

      {pred, nil} ->
        pred

      {nil, pred} ->
        pred
    end
  end

  defp build_predicate(%{op: :not, expr: expr}) do
    case build_predicate(expr) do
      {sql, params} -> {"NOT (#{sql})", params}
      nil -> nil
    end
  end

  # Ash 3.0 filter maps use `:operator` / `:left` / `:right` shape.
  defp build_predicate(%{operator: operator, left: left, right: right}) do
    build_comparison(operator, left, right)
  end

  # Older shape uses `:op` / `:name` / `:right`.
  defp build_predicate(%{op: operator, name: name, right: right}) do
    build_comparison(operator, %{name: name}, right)
  end

  defp build_predicate(_), do: nil

  @spec build_comparison(atom(), term(), term()) :: {String.t(), list()} | nil
  defp build_comparison(operator, left, right)

  defp build_comparison(:eq, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " = ?", [value]}
  end

  defp build_comparison(:==, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " = ?", [value]}
  end

  defp build_comparison(:not_eq, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " != ?", [value]}
  end

  defp build_comparison(:>, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " > ?", [value]}
  end

  defp build_comparison(:>=, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " >= ?", [value]}
  end

  defp build_comparison(:<, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " < ?", [value]}
  end

  defp build_comparison(:<=, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " <= ?", [value]}
  end

  defp build_comparison(:in, %{name: name}, %{value: value}) when is_list(value) do
    placeholders = Enum.map_join(value, ", ", fn _ -> "?" end)
    {"#{Identifier.quote_name(name)} IN (#{placeholders})", value}
  end

  defp build_comparison(:in, %{name: name}, %{value: value}) do
    {Identifier.quote_name(name) <> " IN (?)", [value]}
  end

  defp build_comparison(:not_in, %{name: name}, %{value: value}) when is_list(value) do
    placeholders = Enum.map_join(value, ", ", fn _ -> "?" end)
    {"#{Identifier.quote_name(name)} NOT IN (#{placeholders})", value}
  end

  defp build_comparison(:is_nil, %{name: name}, %{value: true}) do
    {"#{Identifier.quote_name(name)} IS NULL", []}
  end

  defp build_comparison(:is_nil, %{name: name}, %{value: false}) do
    {"#{Identifier.quote_name(name)} IS NOT NULL", []}
  end

  defp build_comparison(:contains, %{name: name}, %{value: value}) do
    {"positionCaseInsensitive(#{Identifier.quote_name(name)}, ?) > 0", [to_string(value)]}
  end

  defp build_comparison(:starts_with, %{name: name}, %{value: value}) do
    {"#{Identifier.quote_name(name)} LIKE ?", [to_string(value) <> "%"]}
  end

  defp build_comparison(:ends_with, %{name: name}, %{value: value}) do
    {"#{Identifier.quote_name(name)} LIKE ?", ["%" <> to_string(value)]}
  end

  defp build_comparison(_operator, _left, _right), do: nil

  @doc """
  Returns the set of column names referenced by a list of filters.
  """
  @spec get_filter_columns(list()) :: [atom()]
  def get_filter_columns(filters) when is_list(filters) do
    Enum.reduce(filters, [], fn filter, acc -> collect_columns(filter) ++ acc end)
    |> Enum.uniq()
  end

  defp collect_columns(%{op: :and, left: left, right: right}) do
    collect_columns(left) ++ collect_columns(right)
  end

  defp collect_columns(%{op: :or, left: left, right: right}) do
    collect_columns(left) ++ collect_columns(right)
  end

  defp collect_columns(%{op: :not, expr: expr}), do: collect_columns(expr)

  defp collect_columns(%{name: name}) when is_atom(name), do: [name]
  defp collect_columns(%{left: %{name: name}}) when is_atom(name), do: [name]
  defp collect_columns(_), do: []

  @doc """
  Quotes a table name, optionally qualifying it with a database.
  """
  @spec qualified_table(String.t() | nil, String.t() | nil) :: String.t()
  def qualified_table(table, database) when is_binary(table) do
    quoted = Identifier.quote_name(table)

    case database do
      nil -> quoted
      db when is_binary(db) -> "#{Identifier.quote_name(db)}.#{quoted}"
      _ -> quoted
    end
  end

  def qualified_table(table, _database), do: to_string(table)

  @doc """
  Quotes a ClickHouse identifier.
  """
  @spec cql_identifier(String.t() | atom()) :: String.t()
  def cql_identifier(name), do: Identifier.quote_name(name)

  defp truncate_integer(value) when is_integer(value), do: value
  defp truncate_integer(value) when is_binary(value), do: value
  defp truncate_integer(value), do: value
end
