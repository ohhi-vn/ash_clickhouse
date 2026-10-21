defmodule AshClickhouse.DataLayer.QueryBuilder do
  @moduledoc """
  Builds ClickHouse SQL from an `AshClickhouse.Query` struct.

  ClickHouse is a full SQL dialect, so most Ash query features map directly:
  `WHERE`, `ORDER BY`, `LIMIT`, `OFFSET`, `SELECT`, `DISTINCT`, `GROUP BY`, and
  aggregate functions are all natively supported.
  """

  alias Ash.Resource.Info
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
  def build_optimized_query(%Query{combination_of: [_ | _] = parts} = query) do
    build_combination_query(query, parts)
  end

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
      group_by: group_by,
      calculations: calculations,
      distinct_sort: distinct_sort
    } = query

    qualified = qualified_table(table, database)

    {where_clause, where_params} = build_where_clause(filters, resource)

    select_columns = resolve_select_columns(distinct, select)

    order_clause = build_order_clause(sorts)
    limit_clause = if limit, do: " LIMIT #{validate_integer!(limit)}", else: ""
    offset_clause = if offset, do: " OFFSET #{validate_integer!(offset)}", else: ""
    group_clause = build_group_clause(group_by)

    if distinct_sort != [] and is_list(distinct) and distinct != [] do
      build_distinct_sort_query(query, qualified, where_clause, where_params, select_columns)
    else
      # ClickHouse requires every ORDER BY expression to appear in the SELECT list
      # for DISTINCT queries. When a sort references a column that is not selected,
      # append it to the select list so the query is valid (the extra column is
      # harmless for dedup semantics since DISTINCT dedupes on the full row).
      select_columns = maybe_add_sorted_distinct_columns(select_columns, sorts, distinct, select)

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

      # The select list comes first in the statement, so its bound parameters
      # precede the WHERE clause's.
      {sql, select_params(select, calculations) ++ where_params}
    end
  end

  # A query with a distinct sort is rendered as
  # `SELECT <cols> ... GROUP BY <distinct cols> ... ORDER BY <distinct sort>
  # LIMIT 1 BY <distinct cols>`.
  #
  # `LIMIT 1 BY` is ClickHouse's equivalent of Postgres's `DISTINCT ON`: it keeps
  # one row per distinct value, taking the first in the query's output order —
  # so the requested sort decides which row is kept. The columns that are not
  # grouped are aggregated with `argMin`/`argMax` over the sort key, so the
  # whole row of the chosen record is returned.
  @spec build_distinct_sort_query(Query.t(), String.t(), String.t(), list(), list()) ::
          {String.t(), list()}
  defp build_distinct_sort_query(query, qualified, where_clause, where_params, select_columns) do
    %Query{distinct: distinct, distinct_sort: distinct_sort, sorts: sorts} = query

    order = distinct_sort ++ sorts
    key = sort_key(order)

    distinct_names = distinct_column_names(distinct)
    grouped = Enum.map(distinct_names, &Identifier.quote_name/1)

    select_clause =
      select_columns
      |> Enum.map_join(", ", fn column ->
        if quoted_name(column) in grouped do
          column
        else
          "#{aggregate_expression(column, key)} AS #{quoted_name(column)}"
        end
      end)

    group_clause = " GROUP BY " <> Enum.join(grouped, ", ")
    order_clause = build_order_clause(order)
    limit_by_clause = " LIMIT 1 BY " <> Enum.join(grouped, ", ")

    sql =
      IO.iodata_to_binary([
        "SELECT ",
        select_clause,
        " FROM ",
        qualified,
        where_clause,
        group_clause,
        order_clause,
        limit_by_clause
      ])

    {sql, where_params}
  end

  # The name of a select column, quoted for comparison with the distinct
  # columns.
  @spec quoted_name(term()) :: String.t()
  defp quoted_name({name, _sql}), do: Identifier.quote_name(name)
  defp quoted_name(name) when is_atom(name) or is_binary(name), do: Identifier.quote_name(name)
  defp quoted_name(name), do: Identifier.quote_name(to_string(name))

  # The distinct columns Ash supplies are `{field, direction}` pairs.
  @spec distinct_column_names(list()) :: [atom()]
  defp distinct_column_names(distinct) do
    Enum.map(distinct, fn
      {field, _direction} -> field
      field -> field
    end)
  end

  # The sort key the aggregated columns are picked by: the first sort entry.
  @spec sort_key(list()) :: {atom(), atom()} | nil
  defp sort_key([{field, direction} | _rest]) when is_atom(field), do: {field, direction}
  defp sort_key(_sorts), do: nil

  # The aggregate that picks the value of a non-grouped column from the row
  # that comes first under the sort.
  @spec aggregate_expression(String.t(), {atom(), atom()} | nil) :: String.t()
  defp aggregate_expression(sql, nil), do: "any(#{sql})"

  defp aggregate_expression(sql, {field, :desc}),
    do: "argMax(#{sql}, #{Identifier.quote_name(field)})"

  defp aggregate_expression(sql, {field, _direction}),
    do: "argMin(#{sql}, #{Identifier.quote_name(field)})"

  # Collects the bound parameters of the expression entries in the select list,
  # in the order the expressions appear in it.
  @spec select_params(term(), list()) :: list()
  defp select_params(select, calculations) do
    params_by_name = Map.new(calculations, &{to_string(&1.name), &1.params})

    select
    |> List.wrap()
    |> Enum.filter(&match?({_name, _sql}, &1))
    |> Enum.flat_map(fn {name, _sql} ->
      Map.get(params_by_name, to_string(name), [])
    end)
    |> Enum.map(fn
      {_column, value} -> value
      value -> value
    end)
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
        Enum.map(merged, &render_select_column/1)

      {_, cols} when is_list(cols) and cols != [] ->
        Enum.map(cols, &render_select_column/1)

      _ ->
        []
    end
  end

  # A plain column renders as its quoted name; an expression renders as
  # `<sql> AS <quoted name>` so the result column can be addressed by name.
  @spec render_select_column(term()) :: String.t()
  defp render_select_column({name, sql}) when is_binary(sql) do
    "#{sql} AS #{Identifier.quote_name(name)}"
  end

  defp render_select_column({name, _direction}) when is_atom(name) or is_binary(name) do
    Identifier.quote_name(name)
  end

  defp render_select_column(name) when is_atom(name) or is_binary(name) do
    Identifier.quote_name(name)
  end

  defp render_select_column(name), do: Identifier.quote_name(to_string(name))

  defp maybe_add_sorted_distinct_columns(select_columns, sorts, distinct, select)
       when is_list(distinct) and distinct != [] and select_columns != [] do
    sorted_columns = Enum.flat_map(sorts, &sort_columns/1)
    selected = selected_names(select)

    case Enum.reject(sorted_columns, &(to_string(&1) in selected)) do
      [] -> select_columns
      missing -> select_columns ++ Enum.map(missing, &Identifier.quote_name/1)
    end
  end

  defp maybe_add_sorted_distinct_columns(select_columns, _sorts, _distinct, _select),
    do: select_columns

  # The names of the columns the select list covers, so a sorted column that is
  # already selected is not appended twice.
  @spec selected_names(term()) :: [String.t()]
  defp selected_names(select) do
    select
    |> List.wrap()
    |> Enum.map(fn
      {name, _sql} -> to_string(name)
      name when is_atom(name) or is_binary(name) -> to_string(name)
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp sort_columns({field, _direction}) when is_atom(field), do: [field]
  defp sort_columns(field) when is_atom(field), do: [field]
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
        case translate_predicate(filter, resource) do
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

  @doc """
  Combines two WHERE clauses into one.

  Both clauses are the `{clause, params}` pairs `build_where_clause/2` returns.
  The parameters of the left clause come first, matching the order the
  predicates appear in the combined clause.
  """
  @spec merge_where_clauses({String.t(), list()}, {String.t(), list()}) ::
          {String.t(), list()}
  def merge_where_clauses({left, left_params}, {right, right_params}) do
    case {left, right} do
      {"", _} ->
        {right, right_params}

      {_, ""} ->
        {left, left_params}

      _ ->
        {" WHERE " <> strip_where(left) <> " AND " <> strip_where(right),
         left_params ++ right_params}
    end
  end

  @doc """
  Builds the ` ORDER BY <cols>` clause for the given sorts.
  """
  @spec order_clause(list()) :: String.t()
  def order_clause(sorts), do: build_order_clause(sorts)

  defp strip_where(" WHERE " <> rest), do: rest
  defp strip_where(clause), do: clause

  @doc """
  Returns the deepest relationship path the expression filters across.

  The layer expresses a relationship filter as a semi-join over a single
  related table, so a path of more than one hop cannot be translated.
  """
  @spec relationship_path_depth(term()) :: non_neg_integer()
  def relationship_path_depth(expression) do
    case expression do
      %Ash.Query.Ref{relationship_path: path} ->
        length(path)

      %Ash.Query.Not{expression: expression} ->
        relationship_path_depth(expression)

      %Ash.Query.BooleanExpression{left: left, right: right} ->
        max(relationship_path_depth(left), relationship_path_depth(right))

      %{__operator__?: true} ->
        max(
          relationship_path_depth(expression.left),
          relationship_path_depth(expression.right)
        )

      %{__function__?: true} ->
        Enum.reduce(expression.arguments, 0, fn argument, depth ->
          max(depth, relationship_path_depth(argument))
        end)

      _ ->
        0
    end
  end

  # Builds the statement of a combination query: the parts' statements
  # combined with ClickHouse's `UNION` operators.
  #
  # The outer query's own filter, sort, limit and offset apply to the combined
  # result, so they wrap the union in a subquery.
  @spec build_combination_query(Query.t(), list()) :: {String.t(), list()}
  defp build_combination_query(query, parts) do
    {statements, params} =
      parts
      |> Enum.map(fn {_type, part} -> build_optimized_query(part) end)
      |> Enum.unzip()

    types = Enum.map(parts, fn {type, _part} -> type end)

    union =
      statements
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {statement, index} ->
        if index == 0 do
          statement
        else
          "#{set_operator(Enum.at(types, index))} #{statement}"
        end
      end)

    params = Enum.concat(params)

    {where_clause, where_params} = build_where_clause(query.filters, query.resource)
    order_clause = build_order_clause(query.sorts)
    limit_clause = if query.limit, do: " LIMIT #{validate_integer!(query.limit)}", else: ""

    offset_clause =
      if query.offset && query.offset > 0,
        do: " OFFSET #{validate_integer!(query.offset)}",
        else: ""

    if where_clause == "" and order_clause == "" and limit_clause == "" and offset_clause == "" do
      {union, params}
    else
      select_clause =
        case query.select do
          cols when is_list(cols) and cols != [] ->
            Enum.map_join(cols, ", ", &Identifier.quote_name/1)

          _other ->
            "*"
        end

      {"SELECT #{select_clause} FROM (#{union})#{where_clause}#{order_clause}#{limit_clause}#{offset_clause}",
       params ++ where_params}
    end
  end

  @doc """
  The ClickHouse set operator for a combination type.
  """
  @spec set_operator(atom()) :: String.t()
  def set_operator(:union_all), do: "UNION ALL"
  def set_operator(:union), do: "UNION DISTINCT"
  def set_operator(:base), do: "UNION ALL"
  def set_operator(_type), do: "UNION ALL"

  # Builds a single predicate (SQL fragment + column + params) from an Ash filter
  # expr. Returns `{sql, column, params}` where `column` is the referenced column
  # name (used for type-aware UUID parameter conversion) and `params` is a list
  # of `{column, value}` tuples, or `nil` when the predicate is untranslatable.
  @spec build_predicate(term(), module() | nil) :: {String.t(), term(), list()} | nil
  defp build_predicate(nil, _resource), do: nil

  defp build_predicate(%{op: :and, left: left, right: right}, resource) do
    case {build_predicate(left, resource), build_predicate(right, resource)} do
      {{l_sql, l_col, l_p}, {r_sql, _r_col, r_p}} ->
        {"(#{l_sql} AND #{r_sql})", l_col, l_p ++ r_p}

      # A child that cannot be translated makes the whole conjunction
      # untranslatable. Returning `nil` lets the top-level `translate_predicate`
      # warn/raise instead of silently dropping part of the filter.
      _ ->
        nil
    end
  end

  defp build_predicate(%{op: :or, left: left, right: right}, resource) do
    case {build_predicate(left, resource), build_predicate(right, resource)} do
      {{l_sql, l_col, l_p}, {r_sql, _r_col, r_p}} ->
        {"(#{l_sql} OR #{r_sql})", l_col, l_p ++ r_p}

      _ ->
        nil
    end
  end

  defp build_predicate(%Ash.Query.BooleanExpression{op: :not, left: left, right: right}, resource) do
    child = if right != nil, do: right, else: left

    case build_predicate(child, resource) do
      {sql, col, params} -> {"(NOT #{sql})", col, params}
      nil -> nil
    end
  end

  # Ash 3.x represents `not` as a dedicated operator struct rather than a
  # BooleanExpression with an `:expr` field.
  defp build_predicate(%Ash.Query.Not{expression: expression}, resource) do
    case build_predicate(expression, resource) do
      {sql, col, params} -> {"(NOT #{sql})", col, params}
      nil -> nil
    end
  end

  # An existence check over an unrelated resource becomes `EXISTS (SELECT 1
  # FROM <resource's table> WHERE <predicate>)`.
  defp build_predicate(
         %Ash.Query.Exists{related?: false, resource: related, expr: expr},
         _resource
       )
       when not is_nil(related) do
    case translate_predicate(expr, related) do
      {inner_sql, _columns, params} ->
        {"EXISTS (SELECT 1 FROM #{related_table(related)} WHERE #{inner_sql})", nil, params}

      nil ->
        nil
    end
  end

  # Every remaining filter shape — the concrete Ash operator and function
  # structs and the legacy `{op, name, right}` map — is normalised into a
  # shared `(operator, left, right)` triple and translated from there, so both
  # shapes reach the same translation.
  defp build_predicate(expr, resource) do
    case normalize_expression(expr) do
      {:ok, operator, %Ash.Query.Ref{relationship_path: path} = left, right} when path != [] ->
        build_semi_join(expr, operator, left, right, path, resource)

      {:ok, operator, left, right} ->
        build_comparison(operator, left, right)

      :error ->
        nil
    end
  end

  # Translates a filter that references an attribute of a related resource into
  # a semi-join: the queried resource's join key is tested against a subquery
  # over the related table. A semi-join keeps the number of returned rows
  # independent of how many related rows match, which a full join would not.
  @spec build_semi_join(term(), atom(), term(), term(), list(), module() | nil) ::
          {String.t(), term(), list()} | nil
  defp build_semi_join(_expr, _operator, _left, _right, path, _resource)
       when length(path) > 1,
       do: nil

  defp build_semi_join(expr, _operator, _left, _right, [relationship_name], resource)
       when not is_nil(resource) do
    relationship = Info.relationship(resource, relationship_name)

    if is_nil(relationship) do
      nil
    else
      related = relationship.destination
      source_attribute = relationship.source_attribute
      destination_attribute = relationship.destination_attribute

      inner_expression = strip_relationship_path(expr, [relationship_name])

      case translate_predicate(inner_expression, related) do
        {inner_sql, _columns, inner_params} ->
          inner_params =
            Enum.map(inner_params, fn {column, value} ->
              {column,
               Types.convert_uuid_param(
                 value,
                 column,
                 MapSet.to_list(Types.uuid_attribute_names(related))
               )}
            end)

          subquery =
            "SELECT #{Identifier.quote_name(destination_attribute)} " <>
              "FROM #{related_table(related)} WHERE #{inner_sql}"

          {"#{Identifier.quote_name(source_attribute)} IN (#{subquery})", source_attribute,
           inner_params}

        nil ->
          nil
      end
    end
  end

  defp build_semi_join(_expr, _operator, _left, _right, _path, _resource), do: nil

  # Rewrites the references of an expression so that the leading relationship
  # of `path` is removed from them — the expression is then translated against
  # the related resource.
  @spec strip_relationship_path(term(), list()) :: term()
  def strip_relationship_path(expr, path) do
    do_strip_relationship_path(expr, path)
  end

  defp do_strip_relationship_path(%Ash.Query.Ref{relationship_path: [first | rest]} = ref, [
         first | prefix
       ]) do
    %{ref | relationship_path: prefix ++ rest}
  end

  defp do_strip_relationship_path(%{__operator__?: true} = expr, path) do
    %{
      expr
      | left: do_strip_relationship_path(expr.left, path),
        right: do_strip_relationship_path(expr.right, path)
    }
  end

  defp do_strip_relationship_path(%{__function__?: true} = expr, path) do
    %{expr | arguments: Enum.map(expr.arguments, &do_strip_relationship_path(&1, path))}
  end

  defp do_strip_relationship_path(expr, _path), do: expr

  # The qualified table of a resource, used by the semi-join and existence
  # subqueries.
  @spec related_table(module()) :: String.t()
  defp related_table(resource) do
    AshClickhouse.DataLayer.qualified_table(resource)
  end

  # Translates a single filter, logging a warning (or raising, when
  # `:raise_on_untranslatable_filter` is enabled) when the filter cannot be
  # expressed in SQL. A silently-dropped filter would produce a *less*
  # restrictive query (e.g. for `base_filter` or tenant scoping) and can leak
  # rows, so we surface it instead of ignoring it.
  @spec translate_predicate(term(), module() | nil) :: {String.t(), term(), list()} | nil
  # A filter whose expression is `true` matches every row, so it adds no
  # restriction to the query. Ash produces it for a filter that was emptied
  # out (e.g. an aggregate with no filter of its own), and it is not an
  # untranslatable filter — there is simply nothing to express.
  defp translate_predicate(true, _resource), do: nil

  defp translate_predicate(filter, resource) do
    case build_predicate(filter, resource) do
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

  # ============================================================================
  # Value expressions (calculation expressions)
  # ============================================================================

  # The arithmetic operators a calculation's expression tree can contain,
  # mapped to the SQL operator they render as.
  @value_operators %{+: "+", -: "-", *: "*", /: "/"}

  # The operator structs a calculation's expression tree can contain, mapped to
  # the SQL operator they render as. Ash rewrites an operator call into the
  # corresponding operator struct when it hydrates the expression's references.
  @value_operator_structs %{
    Ash.Query.Operator.Eq => "=",
    Ash.Query.Operator.NotEq => "!=",
    Ash.Query.Operator.GreaterThan => ">",
    Ash.Query.Operator.GreaterThanOrEqual => ">=",
    Ash.Query.Operator.LessThan => "<",
    Ash.Query.Operator.LessThanOrEqual => "<=",
    Ash.Query.Operator.Basic.Plus => "+",
    Ash.Query.Operator.Basic.Times => "*",
    Ash.Query.Operator.Basic.Minus => "-",
    Ash.Query.Operator.Basic.Div => "/"
  }

  # The operator structs whose SQL rendering is not a plain infix operator.
  @special_value_operator_structs [
    Ash.Query.Operator.Basic.Concat,
    Ash.Query.Operator.Basic.Or,
    Ash.Query.Operator.Basic.And,
    Ash.Query.Operator.IsNil
  ]

  @doc """
  Renders a calculation's expression tree to a SQL fragment.

  Handles the `%Ash.Query.Function.Type{arguments: [expr, type, constraints]}`
  wrapper Ash supplies for a typed calculation by casting the inner
  expression, the column references within, and the operators between them.
  Literals are bound as query parameters rather than interpolated into the
  SQL text.

  Returns `{sql, params}` where `params` is a list of `{column, value}` tuples
  (the column is `nil` for a literal), or `nil` when the expression cannot be
  rendered — the caller then falls back to evaluating the expression against
  the decoded record.
  """
  @spec build_value_expression(term(), list()) :: {String.t(), list()} | nil
  def build_value_expression(expression, params \\ [])

  def build_value_expression(
        %Ash.Query.Function.Type{arguments: [inner, type, _constraints]},
        params
      ) do
    case build_value_expression(inner, params) do
      {sql, params} ->
        {"CAST(#{sql} AS #{Types.ash_type_to_clickhouse(type)})", params}

      nil ->
        nil
    end
  end

  def build_value_expression(%{__operator__?: true} = expr, params) do
    operator_sql = Map.get(@value_operator_structs, expr.__struct__)

    cond do
      not is_nil(operator_sql) ->
        with {l_sql, params} <- build_value_expression(expr.left, params),
             {r_sql, params} <- build_value_expression(expr.right, params) do
          {"(#{l_sql} #{operator_sql} #{r_sql})", params}
        end

      expr.__struct__ == Ash.Query.Operator.Basic.Concat ->
        with {l_sql, params} <- build_value_expression(expr.left, params),
             {r_sql, params} <- build_value_expression(expr.right, params) do
          {"concat(#{l_sql}, #{r_sql})", params}
        end

      expr.__struct__ == Ash.Query.Operator.Basic.Or ->
        with {l_sql, params} <- build_value_expression(expr.left, params),
             {r_sql, params} <- build_value_expression(expr.right, params) do
          {"(#{l_sql} OR #{r_sql})", params}
        end

      expr.__struct__ == Ash.Query.Operator.Basic.And ->
        with {l_sql, params} <- build_value_expression(expr.left, params),
             {r_sql, params} <- build_value_expression(expr.right, params) do
          {"(#{l_sql} AND #{r_sql})", params}
        end

      expr.__struct__ == Ash.Query.Operator.IsNil ->
        with {l_sql, params} <- build_value_expression(expr.left, params) do
          {"(#{l_sql} IS NULL)", params}
        end

      true ->
        nil
    end
  end

  def build_value_expression(%Ash.Query.Ref{} = ref, params) do
    case column_name(ref) do
      nil -> nil
      name -> {Identifier.quote_name(name), params}
    end
  end

  def build_value_expression(%Ash.Query.Call{name: name, args: args}, params) do
    build_value_call(name, args, params)
  end

  def build_value_expression(value, params)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_atom(value) do
    {"?", params ++ [{nil, value}]}
  end

  def build_value_expression(_expression, _params), do: nil

  defp build_value_call(name, [left, right], params) when is_map_key(@value_operators, name) do
    with {l_sql, params} <- build_value_expression(left, params),
         {r_sql, params} <- build_value_expression(right, params) do
      {"(#{l_sql} #{@value_operators[name]} #{r_sql})", params}
    end
  end

  # String concatenation.
  defp build_value_call(:<>, [left, right], params) do
    with {l_sql, params} <- build_value_expression(left, params),
         {r_sql, params} <- build_value_expression(right, params) do
      {"concat(#{l_sql}, #{r_sql})", params}
    end
  end

  defp build_value_call(:||, [left, right], params) do
    with {l_sql, params} <- build_value_expression(left, params),
         {r_sql, params} <- build_value_expression(right, params) do
      {"(#{l_sql} OR #{r_sql})", params}
    end
  end

  defp build_value_call(:&&, [left, right], params) do
    with {l_sql, params} <- build_value_expression(left, params),
         {r_sql, params} <- build_value_expression(right, params) do
      {"(#{l_sql} AND #{r_sql})", params}
    end
  end

  defp build_value_call(_name, _args, _params), do: nil

  # ============================================================================
  # Expression normalization
  # ============================================================================

  # The Ash operator structs the layer can translate into a ClickHouse
  # predicate, mapped to the canonical operator atom used by
  # `build_value_comparison/3`.
  #
  # This table is the single source of truth shared with
  # `supported_expression?/1` (which backs `can?({:filter_expr, expr})`), so the
  # reported capability and the delivered translation cannot drift apart.
  @supported_operators %{
    Ash.Query.Operator.Eq => :eq,
    Ash.Query.Operator.NotEq => :not_eq,
    Ash.Query.Operator.GreaterThan => :>,
    Ash.Query.Operator.GreaterThanOrEqual => :>=,
    Ash.Query.Operator.LessThan => :<,
    Ash.Query.Operator.LessThanOrEqual => :<=,
    Ash.Query.Operator.In => :in,
    Ash.Query.Operator.IsNil => :is_nil,
    Ash.Query.Operator.Has => :has,
    Ash.Query.Operator.Overlaps => :overlaps
  }

  # The Ash function structs the layer can translate, mapped to the operator
  # atom used by `build_value_comparison/3`. `is_nil` takes a single argument
  # and is normalised to the null comparison; the rest take two.
  @supported_functions %{
    Ash.Query.Function.Contains => :contains,
    Ash.Query.Function.StringStartsWith => :starts_with,
    Ash.Query.Function.StringEndsWith => :ends_with,
    Ash.Query.Function.IsNil => :is_nil,
    Ash.Query.Function.Has => :has,
    Ash.Query.Function.Intersects => :intersects
  }

  # The functions the layer publishes for use in filters, mapped to the SQL
  # function they are translated into.
  @published_functions %{
    AshClickhouse.Functions.Match => "match"
  }

  @doc """
  Returns `true` when `expr` can be translated into a ClickHouse predicate.

  This is the single source of truth behind `can?({:filter_expr, expr})`: the
  table it consults is the same one the translator uses, so an expression the
  layer reports as unsupported is never attempted, and one it reports as
  supported is always translatable.

  The value operators a calculation's expression tree contains are reported as
  supported too — Ash consults the same capability when it hydrates a
  calculation's expression.
  """
  @spec supported_expression?(term()) :: boolean()
  def supported_expression?(expr) do
    match?({:ok, _operator, _left, _right}, normalize_expression(expr)) or
      match?({:ok, _operator, _left, _right}, normalize_value_expression(expr))
  end

  @doc """
  Normalises a value expression — the tree of a calculation's expression —
  into a shared `(operator, left, right)` triple.
  """
  @spec normalize_value_expression(term()) :: {:ok, atom(), term(), term()} | :error
  def normalize_value_expression(%{__operator__?: true} = expr) do
    if Map.has_key?(@value_operator_structs, expr.__struct__) or
         expr.__struct__ in @special_value_operator_structs do
      {:ok, expr.operator, expr.left, expr.right}
    else
      :error
    end
  end

  def normalize_value_expression(_expr), do: :error

  @doc """
  Normalises an Ash filter expression into a shared `(operator, left, right)`
  triple.

  Returns `:error` for expressions the layer cannot translate. Both the
  concrete Ash operator/function structs and the legacy
  `%{op: operator, name: name, right: right}` map (still produced by
  `set_tenant/3` for attribute-based multitenancy) normalise to the same
  triple, so both reach the same translation.
  """
  @spec normalize_expression(term()) :: {:ok, atom(), term(), term()} | :error
  def normalize_expression(%{__operator__?: true} = expr) do
    case Map.fetch(@supported_operators, expr.__struct__) do
      {:ok, operator} -> {:ok, operator, expr.left, expr.right}
      :error -> :error
    end
  end

  def normalize_expression(%{__function__?: true} = expr) do
    case Map.fetch(@supported_functions, expr.__struct__) do
      {:ok, :is_nil} ->
        case expr.arguments do
          [argument] -> {:ok, :is_nil, argument, true}
          _ -> :error
        end

      {:ok, operator} ->
        case expr.arguments do
          [left, right] -> {:ok, operator, left, right}
          _ -> :error
        end

      :error ->
        case Map.fetch(@published_functions, expr.__struct__) do
          {:ok, _function} ->
            case expr.arguments do
              [_left, right] -> {:ok, :published_function, expr, right}
              _ -> :error
            end

          :error ->
            :error
        end
    end
  end

  # Legacy shape uses `:op` / `:name` / `:right`.
  def normalize_expression(%{op: operator, name: name, right: right})
      when is_atom(operator) do
    {:ok, operator, name, right}
  end

  # Generic shape uses `:operator` / `:left` / `:right`.
  def normalize_expression(%{operator: operator, left: left, right: right})
      when is_atom(operator) do
    {:ok, operator, left, right}
  end

  def normalize_expression(_), do: :error

  # Resolves the column a filter operand refers to. Accepts an `Ash.Query.Ref`,
  # a plain `%{name: name}` map, or a bare atom/binary column name. Returns
  # `nil` for anything else (including aggregate and calculation references,
  # which are not plain columns).
  @spec column_name(term()) :: atom() | String.t() | nil
  defp column_name(%Ash.Query.Ref{attribute: %{name: name}}), do: name
  defp column_name(%Ash.Query.Ref{attribute: name}) when is_atom(name), do: name
  defp column_name(%Ash.Query.Ref{attribute: name}) when is_binary(name), do: name
  defp column_name(%{__struct__: _}), do: nil
  defp column_name(%{name: name}) when is_atom(name), do: name
  defp column_name(%{name: name}) when is_binary(name), do: name
  defp column_name(name) when is_atom(name), do: name
  defp column_name(name) when is_binary(name), do: name
  defp column_name(_), do: nil

  # Resolves a column *reference*. Unlike `column_name/1`, a bare binary is not
  # accepted: in a right-hand operand a binary is a literal value, not a
  # column name.
  @spec referenced_column(term()) :: atom() | String.t() | nil
  defp referenced_column(%Ash.Query.Ref{attribute: %{name: name}}), do: name
  defp referenced_column(%Ash.Query.Ref{attribute: name}) when is_atom(name), do: name
  defp referenced_column(%Ash.Query.Ref{attribute: name}) when is_binary(name), do: name
  defp referenced_column(%{__struct__: _}), do: nil
  defp referenced_column(%{name: name}) when is_atom(name), do: name
  defp referenced_column(%{name: name}) when is_binary(name), do: name
  defp referenced_column(_), do: nil

  # The legacy filter shape wrapped literals in `%{value: value}`.
  @spec unwrap_value(term()) :: term()
  defp unwrap_value(%{__struct__: _} = value), do: value
  defp unwrap_value(%{value: value}), do: value
  defp unwrap_value(value), do: value

  # When `true`, `contains` uses a case-sensitive substring search
  # (`position()`), matching the case-sensitivity of `starts_with`/`ends_with`.
  # Defaults to `false` (case-insensitive `positionCaseInsensitive`), which is
  # the historical behaviour. Configure via
  # `config :ash_clickhouse, :case_sensitive_contains, true`.
  @spec case_sensitive_contains?() :: boolean()
  defp case_sensitive_contains? do
    Application.get_env(:ash_clickhouse, :case_sensitive_contains, false)
  end

  # Builds a comparison predicate from a normalised `(operator, left, right)`
  # triple.
  #
  # `left` is the column being compared — an `Ash.Query.Ref`, a plain
  # `%{name: name}` map, or a bare atom/binary column name. `right` is the
  # value (or, for the two-array operators, the second column) it is compared
  # against.
  @spec build_comparison(atom(), term(), term()) :: {String.t(), term(), list()} | nil
  defp build_comparison(:published_function, function, right) do
    with name when not is_nil(name) <- Map.get(@published_functions, function.__struct__),
         [left | _rest] <- function.arguments,
         {l_sql, params} <- build_value_expression(left, []),
         {r_sql, params} <- build_value_expression(right, params) do
      {"#{name}(#{l_sql}, #{r_sql})", nil, params}
    else
      _other -> nil
    end
  end

  defp build_comparison(operator, left, right) do
    case column_name(left) do
      nil -> nil
      name -> build_column_comparison(operator, name, right)
    end
  end

  # `intersects` compares two array *columns*, so both sides are columns.
  defp build_column_comparison(:intersects, name, right) do
    case referenced_column(right) do
      nil ->
        nil

      other ->
        {"notEmpty(arrayIntersect(#{Identifier.quote_name(name)}, " <>
           "#{Identifier.quote_name(other)}))", name, []}
    end
  end

  # `overlaps` compares an array column against a list of values; the list is
  # bound as a single array parameter.
  defp build_column_comparison(:overlaps, name, right) do
    values =
      right
      |> unwrap_value()
      |> to_value_list()

    {"notEmpty(arrayIntersect(#{Identifier.quote_name(name)}, ?))", name, [{name, values}]}
  end

  defp build_column_comparison(operator, name, right) do
    build_value_comparison(operator, name, unwrap_value(right))
  end

  # Normalises a value that may be a list, a `MapSet` (which is how Ash's `in`
  # and `overlaps` operators carry their value set), or a single value.
  @spec to_value_list(term()) :: list()
  defp to_value_list(value) when is_list(value), do: value
  defp to_value_list(%MapSet{} = value), do: MapSet.to_list(value)
  defp to_value_list(value), do: [value]

  @spec build_value_comparison(atom(), atom() | String.t(), term()) ::
          {String.t(), term(), list()} | nil
  defp build_value_comparison(operator, name, value)

  defp build_value_comparison(:eq, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " = ?", name, [{name, value}]}
  end

  defp build_value_comparison(:==, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " = ?", name, [{name, value}]}
  end

  defp build_value_comparison(:not_eq, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " != ?", name, [{name, value}]}
  end

  # Ash's `!=` operator (`Ash.Query.Operator.NotEq`) carries `operator: :!=`;
  # the legacy shape used `:not_eq`. Both spellings are accepted.
  defp build_value_comparison(:!=, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " != ?", name, [{name, value}]}
  end

  defp build_value_comparison(:>, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " > ?", name, [{name, value}]}
  end

  defp build_value_comparison(:>=, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " >= ?", name, [{name, value}]}
  end

  defp build_value_comparison(:<, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " < ?", name, [{name, value}]}
  end

  defp build_value_comparison(:<=, name, value) when is_atom(name) or is_binary(name) do
    {Identifier.quote_name(name) <> " <= ?", name, [{name, value}]}
  end

  defp build_value_comparison(:in, name, value)
       when (is_atom(name) or is_binary(name)) and is_list(value) do
    build_in(name, value, "IN")
  end

  defp build_value_comparison(:in, name, value) when is_atom(name) or is_binary(name) do
    if is_struct(value, MapSet) do
      build_value_comparison(:in, name, MapSet.to_list(value))
    else
      {Identifier.quote_name(name) <> " IN (?)", name, [{name, value}]}
    end
  end

  defp build_value_comparison(:not_in, name, value)
       when (is_atom(name) or is_binary(name)) and is_list(value) do
    build_in(name, value, "NOT IN")
  end

  defp build_value_comparison(:not_in, name, value) when is_atom(name) or is_binary(name) do
    if is_struct(value, MapSet) do
      build_value_comparison(:not_in, name, MapSet.to_list(value))
    else
      {Identifier.quote_name(name) <> " NOT IN (?)", name, [{name, value}]}
    end
  end

  # ClickHouse's `has(array, value)` tests array membership.
  defp build_value_comparison(:has, name, value) when is_atom(name) or is_binary(name) do
    {"has(#{Identifier.quote_name(name)}, ?)", name, [{name, value}]}
  end

  # `%` and `_` in the value are treated literally (no LIKE-wildcard
  # injection) because `position`/`positionCaseInsensitive` are substring
  # searches, not LIKE patterns.
  defp build_value_comparison(:contains, name, value) when is_atom(name) or is_binary(name) do
    if case_sensitive_contains?() do
      {"position(#{Identifier.quote_name(name)}, ?) > 0", name, [{name, to_string(value)}]}
    else
      {"positionCaseInsensitive(#{Identifier.quote_name(name)}, ?) > 0", name,
       [{name, to_string(value)}]}
    end
  end

  defp build_value_comparison(:like, name, value) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} LIKE ?", name, [{name, to_string(value)}]}
  end

  defp build_value_comparison(:ilike, name, value) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} ILIKE ?", name, [{name, to_string(value)}]}
  end

  defp build_value_comparison(:starts_with, name, value) when is_atom(name) or is_binary(name) do
    escaped = escape_like(value)

    {"#{Identifier.quote_name(name)} LIKE ? ESCAPE '#{@like_escape}'", name,
     [{name, escaped <> "%"}]}
  end

  defp build_value_comparison(:ends_with, name, value) when is_atom(name) or is_binary(name) do
    escaped = escape_like(value)

    {"#{Identifier.quote_name(name)} LIKE ? ESCAPE '#{@like_escape}'", name,
     [{name, "%" <> escaped}]}
  end

  defp build_value_comparison(:is_nil, name, true) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} IS NULL", name, []}
  end

  defp build_value_comparison(:is_nil, name, false) when is_atom(name) or is_binary(name) do
    {"#{Identifier.quote_name(name)} IS NOT NULL", name, []}
  end

  defp build_value_comparison(_operator, _left, _right), do: nil

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

  # Concrete Ash operator and function structs, plus the legacy map shapes.
  defp collect_columns(expr) do
    case normalize_expression(expr) do
      {:ok, _operator, left, right} ->
        List.wrap(column_name(left)) ++ List.wrap(referenced_column(right))

      :error ->
        []
    end
  end

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
