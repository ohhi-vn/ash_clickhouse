defmodule AshClickhouse.DataLayer.QueryBuilder do
  @moduledoc """
  Builds ClickHouse SQL from an `AshClickhouse.Query` struct.

  ClickHouse is a full SQL dialect, so most Ash query features map directly:
  `WHERE`, `ORDER BY`, `LIMIT`, `OFFSET`, `SELECT`, `DISTINCT`, `GROUP BY`, and
  aggregate functions are all natively supported.
  """

  alias AshClickhouse.DataLayer.Types
  alias AshClickhouse.Identifier
  alias AshClickhouse.Query

  require Logger

  # Escape character used when quoting `%`/`_` wildcards inside LIKE patterns
  # (see `escape_like/1`). Chosen as a backslash because it is unlikely to
  # appear in real search input and is a valid ClickHouse LIKE escape char.
  @like_escape "\\"

  # When `true`, an untranslatable filter raises instead of being silently
  # dropped. Configure via `config :ash_clickhouse, :raise_on_untranslatable_filter, true`.
  #
  # Defaults to `true` (fail-closed). An untranslatable filter on a `base_filter`
  # (commonly used for tenant scoping or soft-delete) that is silently dropped
  # makes the query *less* restrictive than intended — a fail-open default that
  # can leak rows across tenants. We default to raising so such misconfigurations
  # surface loudly rather than silently returning too many rows.

  @spec raise_on_untranslatable?() :: boolean()
  defp raise_on_untranslatable? do
    Application.get_env(:ash_clickhouse, :raise_on_untranslatable_filter, true)
  end

  # Builds the ` ORDER BY <cols>` clause for the given sorts.
  defp build_order_clause(sorts) when sorts == [] or is_nil(sorts), do: ""

  defp build_order_clause(sorts) do
    " ORDER BY " <>
      Enum.map_join(sorts, ", ", fn
        {field, :asc} -> "#{Identifier.quote_name(field)} ASC"
        {field, :desc} -> "#{Identifier.quote_name(field)} DESC"
        {field, :asc_nils_first} -> "#{Identifier.quote_name(field)} ASC NULLS FIRST"
        {field, :asc_nils_last} -> "#{Identifier.quote_name(field)} ASC NULLS LAST"
        {field, :desc_nils_first} -> "#{Identifier.quote_name(field)} DESC NULLS FIRST"
        {field, :desc_nils_last} -> "#{Identifier.quote_name(field)} DESC NULLS LAST"
        field when is_atom(field) -> "#{Identifier.quote_name(field)} ASC"
      end)
  end

  defp build_group_clause(group_by) when is_nil(group_by) or group_by == [], do: ""

  defp build_group_clause(group_by) do
    " GROUP BY " <> Enum.map_join(group_by, ", ", &Identifier.quote_name/1)
  end

  @doc """
  Builds the final SELECT query and parameter list.
  """
  @spec build_optimized_query(Query.t()) :: {String.t(), list()}
  def build_optimized_query(%Query{} = query) do
    %Query{
      resource: resource,
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

    {where_clause, where_params} = build_where_clause(filters, resource)

    select_columns = resolve_select_columns(distinct, select)

    order_clause = build_order_clause(sorts)
    limit_clause = if limit, do: " LIMIT #{validate_integer!(limit)}", else: ""
    offset_clause = if offset, do: " OFFSET #{validate_integer!(offset)}", else: ""
    group_clause = build_group_clause(group_by)

    # ClickHouse requires every ORDER BY expression to appear in the SELECT list
    # for DISTINCT queries. When a sort references a column that is not selected,
    # append it to the select list so the query is valid (the extra column is
    # harmless for dedup semantics since DISTINCT dedupes on the full row).
    select_columns = maybe_add_sorted_distinct_columns(select_columns, sorts, distinct)

    select_clause =
      if select_columns == [], do: "*", else: Enum.map_join(select_columns, ", ", & &1)

    distinct_prefix = if is_list(distinct) and distinct != [], do: "DISTINCT ", else: ""

    sql =
      IO.iodata_to_binary([
        "SELECT ",
        distinct_prefix,
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

  # Resolves the SELECT list as a list of already-quoted column strings.
  # Returns `[]` when the query selects the whole row (`*`).
  defp resolve_select_columns(distinct, select) do
    case {distinct, select} do
      {cols, _} when is_list(cols) and cols != [] ->
        # ClickHouse dedupes on the full selected row, so we emit the merged
        # select list (which `distinct/3` already unions with the distinct
        # columns) rather than only the distinct columns — otherwise an
        # explicit `select` would silently lose columns. When there is no
        # explicit select, fall back to the distinct columns.
        merged = if select && select != [], do: select, else: cols
        Enum.map(merged, &Identifier.quote_name/1)

      {_, cols} when is_list(cols) and cols != [] ->
        Enum.map(cols, &Identifier.quote_name/1)

      _ ->
        []
    end
  end

  defp maybe_add_sorted_distinct_columns(select_columns, sorts, distinct)
       when is_list(distinct) and distinct != [] and select_columns != [] do
    sorted_columns = Enum.flat_map(sorts, &sort_columns/1)

    case Enum.reject(sorted_columns, &(&1 in select_columns)) do
      [] -> select_columns
      missing -> select_columns ++ missing
    end
  end

  defp maybe_add_sorted_distinct_columns(select_columns, _sorts, _distinct), do: select_columns

  defp sort_columns({field, _direction}) when is_atom(field), do: [Identifier.quote_name(field)]
  defp sort_columns(field) when is_atom(field), do: [Identifier.quote_name(field)]
  defp sort_columns(_), do: []

  @doc """
  Builds a WHERE clause from a list of Ash filter expressions.

  Returns `{clause, params}` where `clause` is either `""` or
  `" WHERE <expr>"`.
  """
  @spec build_where_clause(list()) :: {String.t(), list()}
  def build_where_clause([]), do: {"", []}

  def build_where_clause(filters) when is_list(filters) do
    build_where_clause(filters, nil)
  end

  # Builds a WHERE clause from a list of Ash filter expressions. When `resource`
  # is provided, string parameters that belong to a UUID-typed column are
  # converted to their 16-byte binary form — but only for columns that are
  # provably UUID-typed. This avoids the old heuristic that mangled any
  # 36-character string (e.g. a legitimate `:string` business identifier).
  @spec build_where_clause(list(), module() | nil) :: {String.t(), list()}
  def build_where_clause(filters, resource) when is_list(filters) do
    uuid_fields =
      if resource, do: MapSet.to_list(Types.uuid_attribute_names(resource)), else: []

    {parts, param_chunks} =
      Enum.reduce(filters, {[], []}, fn filter, {parts_acc, chunks_acc} ->
        case translate_predicate(filter) do
          {sql, _columns, new_params} ->
            mapped_params =
              Enum.map(new_params, fn {col, val} ->
                Types.convert_uuid_param(val, col, uuid_fields)
              end)

            {[sql | parts_acc], [mapped_params | chunks_acc]}

          nil ->
            {parts_acc, chunks_acc}
        end
      end)

    parts = Enum.reverse(parts)
    params = param_chunks |> Enum.reverse() |> Enum.concat()

    case parts do
      [] -> {"", []}
      parts -> {" WHERE " <> Enum.join(parts, " AND "), params}
    end
  end

  # Builds a single predicate (SQL fragment + column + params) from an Ash filter
  # expr. Returns `{sql, column, params}` where `column` is the referenced column
  # name (used for type-aware UUID parameter conversion) and `params` is a list
  # of `{column, value}` tuples, or `nil` when the predicate is untranslatable.
  @spec build_predicate(term()) :: {String.t(), term(), list()} | nil
  defp build_predicate(nil), do: nil

  defp build_predicate(%{op: :and, left: left, right: right}) do
    case {build_predicate(left), build_predicate(right)} do
      {{l_sql, l_col, l_p}, {r_sql, _r_col, r_p}} ->
        {"(#{l_sql} AND #{r_sql})", l_col, l_p ++ r_p}

      # A child that cannot be translated makes the whole conjunction
      # untranslatable. Returning `nil` lets the top-level `translate_predicate`
      # warn/raise instead of silently dropping part of the filter.
      _ ->
        nil
    end
  end

  defp build_predicate(%{op: :or, left: left, right: right}) do
    case {build_predicate(left), build_predicate(right)} do
      {{l_sql, l_col, l_p}, {r_sql, _r_col, r_p}} ->
        {"(#{l_sql} OR #{r_sql})", l_col, l_p ++ r_p}

      _ ->
        nil
    end
  end

  defp build_predicate(%Ash.Query.BooleanExpression{op: :not, left: left, right: right}) do
    child = if right != nil, do: right, else: left

    case build_predicate(child) do
      {sql, col, params} -> {"(NOT #{sql})", col, params}
      nil -> nil
    end
  end

  # Ash 3.x represents `not` as a dedicated operator struct rather than a
  # BooleanExpression with an `:expr` field.
  defp build_predicate(%Ash.Query.Not{expression: expression}) do
    case build_predicate(expression) do
      {sql, col, params} -> {"(NOT #{sql})", col, params}
      nil -> nil
    end
  end

  # Ash 3.0 operator structs (e.g. `Ash.Query.Operator.GreaterThanOrEqual`) carry
  # `:operator`, `:left` (an `Ash.Query.Ref`) and `:right` (a raw value).
  defp build_predicate(%{operator: operator, left: %Ash.Query.Ref{} = left, right: right}) do
    build_comparison(operator, ref_name(left), right)
  end

  defp build_predicate(%{operator: operator, left: %{name: name}, right: %{value: value}}) do
    build_comparison(operator, name, value)
  end

  defp build_predicate(%{operator: operator, left: %{name: name}, right: right}) do
    build_comparison(operator, name, right)
  end

  defp build_predicate(%{operator: operator, left: left, right: right}) do
    build_comparison(operator, left, right)
  end

  # Older shape uses `:op` / `:name` / `:right`.
  defp build_predicate(%{op: operator, name: name, right: right}) do
    build_comparison(operator, name, right)
  end

  defp build_predicate(_), do: nil

  # Translates a single filter, logging a warning (or raising, when
  # `:raise_on_untranslatable_filter` is enabled) when the filter cannot be
  # expressed in SQL. A silently-dropped filter would produce a *less*
  # restrictive query (e.g. for `base_filter` or tenant scoping) and can leak
  # rows, so we surface it instead of ignoring it.
  @spec translate_predicate(term()) :: {String.t(), term(), list()} | nil
  defp translate_predicate(filter) do
    case build_predicate(filter) do
      nil ->
        handle_untranslatable_filter(filter)
        nil

      {_sql, _column, _params} = other ->
        other
    end
  end

  defp handle_untranslatable_filter(filter) do
    message =
      "AshClickhouse: dropping untranslatable filter #{inspect(filter)}. " <>
        "This makes the query less restrictive than intended."

    if raise_on_untranslatable?() do
      raise AshClickhouse.Error.QueryError, message
    else
      Logger.warning(message)
    end
  end

  defp ref_name(%Ash.Query.Ref{attribute: %{name: name}}), do: name
  defp ref_name(%Ash.Query.Ref{attribute: name}) when is_atom(name), do: name
  defp ref_name(%Ash.Query.Ref{attribute: name}) when is_binary(name), do: name
  # Fallbacks for callers that pass a bare atom/binary instead of a Ref.
  @dialyzer {:nowarn_function, ref_name: 1}
  defp ref_name(name) when is_atom(name), do: name
  defp ref_name(name) when is_binary(name), do: name

  # When `true`, `contains` uses a case-sensitive substring search
  # (`position()`), matching the case-sensitivity of `starts_with`/`ends_with`.
  # Defaults to `false` (case-insensitive `positionCaseInsensitive`), which is
  # the historical behaviour. Configure via
  # `config :ash_clickhouse, :case_sensitive_contains, true`.
  @spec case_sensitive_contains?() :: boolean()
  defp case_sensitive_contains? do
    Application.get_env(:ash_clickhouse, :case_sensitive_contains, false)
  end

  @spec build_comparison(atom(), term(), term()) :: {String.t(), term(), list()} | nil
  defp build_comparison(operator, left, right)

  defp build_comparison(:eq, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " = ?", name, [{name, value}]}
  end

  defp build_comparison(:==, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " = ?", name, [{name, value}]}
  end

  defp build_comparison(:not_eq, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " != ?", name, [{name, value}]}
  end

  defp build_comparison(:>, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " > ?", name, [{name, value}]}
  end

  defp build_comparison(:>=, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " >= ?", name, [{name, value}]}
  end

  defp build_comparison(:<, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " < ?", name, [{name, value}]}
  end

  defp build_comparison(:<=, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " <= ?", name, [{name, value}]}
  end

  defp build_comparison(:in, name, value)
       when (is_atom(name) or is_binary(name)) and is_list(value) do
    build_in(name, value, "IN")
  end

  defp build_comparison(:in, name, value) when is_atom(name) or is_binary(name) do
    if is_struct(value, MapSet) do
      build_comparison(:in, name, MapSet.to_list(value))
    else
      {Identifier.quote_name(name) <> " IN (?)", name, [{name, value}]}
    end
  end

  defp build_comparison(:not_in, name, value)
       when (is_atom(name) or is_binary(name)) and is_list(value) do
    build_in(name, value, "NOT IN")
  end

  defp build_comparison(:not_in, name, value) when is_atom(name) or is_binary(name) do
    if is_struct(value, MapSet) do
      build_comparison(:not_in, name, MapSet.to_list(value))
    else
      {Identifier.quote_name(name) <> " NOT IN (?)", name, [{name, value}]}
    end
  end

  # `%` and `_` in the value are treated literally (no LIKE-wildcard
  # injection) because `position`/`positionCaseInsensitive` are substring
  # searches, not LIKE patterns.
  defp build_comparison(:contains, name, value) when is_atom(name) or is_binary(name) do
    if case_sensitive_contains?() do
      {"position(#{Identifier.quote_name(name)}, ?) > 0", name, [{name, to_string(value)}]}
    else
      {"positionCaseInsensitive(#{Identifier.quote_name(name)}, ?) > 0", name,
       [{name, to_string(value)}]}
    end
  end

  defp build_comparison(:like, name, value) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} LIKE ?", name, [{name, to_string(value)}]}
  end

  defp build_comparison(:ilike, name, value) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} ILIKE ?", name, [{name, to_string(value)}]}
  end

  defp build_comparison(:starts_with, name, value) when is_atom(name) or is_binary(name) do
    escaped = escape_like(value)

    {"#{Identifier.quote_name(name)} LIKE ? ESCAPE '#{@like_escape}'", name,
     [{name, escaped <> "%"}]}
  end

  defp build_comparison(:ends_with, name, value) when is_atom(name) or is_binary(name) do
    escaped = escape_like(value)

    {"#{Identifier.quote_name(name)} LIKE ? ESCAPE '#{@like_escape}'", name,
     [{name, "%" <> escaped}]}
  end

  defp build_comparison(:is_nil, name, true) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} IS NULL", name, []}
  end

  defp build_comparison(:is_nil, name, false) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} IS NOT NULL", name, []}
  end

  defp build_comparison(_operator, _left, _right), do: nil

  # An empty list would render as `col IN ()`, which ClickHouse rejects as a
  # syntax error. Semantically `col IN ()` is always false and
  # `col NOT IN ()` is always true, so emit those instead.
  defp build_in(name, [], operator) do
    literal = if operator == "IN", do: "0", else: "1"
    {"#{Identifier.quote_name(name)} #{operator} (#{literal})", name, []}
  end

  defp build_in(name, value, operator) do
    placeholders = Enum.map_join(value, ", ", fn _ -> "?" end)

    {"#{Identifier.quote_name(name)} #{operator} (#{placeholders})", name,
     Enum.map(value, &{name, &1})}
  end

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

  defp collect_columns(%Ash.Query.BooleanExpression{op: :not, left: left, right: right}) do
    child = if right != nil, do: right, else: left
    collect_columns(child)
  end

  defp collect_columns(%Ash.Query.Not{expression: expression}) do
    collect_columns(expression)
  end

  defp collect_columns(%{operator: _operator, left: %Ash.Query.Ref{} = left, right: _right}) do
    [ref_name(left)]
  end

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

  def qualified_table(table, database), do: qualified_table(to_string(table), database)

  @doc """
  Quotes a ClickHouse identifier.
  """
  @spec cql_identifier(String.t() | atom()) :: String.t()
  def cql_identifier(name), do: Identifier.quote_name(name)

  defp validate_integer!(value) when is_integer(value), do: value

  defp validate_integer!(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> raise ArgumentError, "limit/offset must be an integer, got: #{inspect(value)}"
    end
  end

  defp validate_integer!(value) do
    raise ArgumentError, "limit/offset must be an integer, got: #{inspect(value)}"
  end

  # Escapes ClickHouse `LIKE` wildcards (`%` and `_`) as well as the escape
  # character itself, so a literal value such as `"50% off"` matches only that
  # exact substring rather than any row containing `50` followed by anything.
  @spec escape_like(term()) :: String.t()
  defp escape_like(value) do
    value
    |> to_string()
    |> String.replace(@like_escape, @like_escape <> @like_escape)
    |> String.replace("%", @like_escape <> "%")
    |> String.replace("_", @like_escape <> "_")
  end
end
