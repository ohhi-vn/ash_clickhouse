defmodule AshClickhouse.DataLayer.Aggregate do
  @moduledoc """
  SQL construction, execution, and in-memory attachment of Ash aggregates.

  Extracted from `AshClickhouse.DataLayer` so the aggregate behaviour (native
  `COUNT/SUM/AVG/MIN/MAX` queries plus batched relationship aggregates) lives in
  one focused module. Relationship aggregates are computed with one grouped query
  per aggregate across the whole result set rather than one query per record.

  An aggregate's own `filter`, `sort` and `join_filters` are applied to the
  rows the aggregate considers, so a filtered aggregate reports the value of
  the matching rows rather than of every row.
  """

  require Logger

  alias Ash.Resource.Info
  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.DataLayer.Types
  alias AshClickhouse.Identifier

  @doc """
  Runs one query per aggregate and folds the results into a map
  (`aggregate.name => value`).
  """
  @spec run(Enumerable.t(), Ash.Resource.t(), module(), String.t(), String.t(), list()) ::
          {:ok, map()} | {:error, term()}
  def run(aggregates, resource, repo, qualified, where_clause, where_params) do
    Enum.reduce_while(aggregates, %{}, fn aggregate, acc ->
      case build_aggregate_query(aggregate, qualified, where_clause, where_params, resource) do
        {:error, reason} ->
          {:halt, {:error, reason}}

        {query, params} ->
          run_one(resource, repo, query, params, acc, aggregate)
      end
    end)
  end

  @doc """
  Attaches relationship-aggregate values onto decoded records, using one batched
  query per aggregate instead of one per (record, aggregate) pair.
  """
  @spec attach([map()], [term()], module(), module(), keyword()) :: [map()]
  def attach(records, [], _resource, _repo, _opts), do: records

  def attach(records, _aggregates, _resource, nil, _opts), do: records

  def attach(records, aggregates, resource, repo, opts) do
    pkey = Info.primary_key(resource)
    uuid_fields = Types.uuid_attribute_names(resource)

    aggregate_maps =
      Map.new(aggregates, fn aggregate ->
        {aggregate.name,
         batched_values(aggregate, records, pkey, resource, repo, opts, uuid_fields)}
      end)

    Enum.map(records, fn record ->
      pk_key = pk_lookup_key(record, pkey)

      agg_values =
        Map.new(aggregates, fn aggregate ->
          values = Map.fetch!(aggregate_maps, aggregate.name)
          {aggregate.name, Map.get(values, pk_key, default_value(aggregate))}
        end)

      Map.update!(record, :aggregates, &Map.merge(&1, agg_values))
    end)
  end

  # --- individual aggregate execution ---------------------------------------

  defp run_one(resource, repo, query, params, acc, aggregate) do
    opts = DataLayer.build_opts(resource)

    case repo.query(query, params, opts) do
      {:ok, %ClickHouse.Result{rows: rows}} ->
        {:cont, Map.put(acc, aggregate.name, decode_rows(rows, aggregate, resource))}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # Folds the rows an aggregate query returned into the aggregate's value.
  #
  # A `count` over no rows is zero rather than absent; a `first` over no rows
  # falls back to the aggregate's declared default.
  @spec decode_rows(list(), map(), module()) :: term()
  defp decode_rows([], aggregate, _resource), do: default_value(aggregate)

  defp decode_rows(rows, aggregate, resource) do
    kind = Map.get(aggregate, :kind)
    field = Map.get(aggregate, :field)

    case kind do
      :count ->
        rows
        |> List.first()
        |> List.first()
        |> decode_aggregate(:count, field, resource)

      :exists ->
        true

      :list ->
        rows
        |> Enum.map(fn row -> row |> List.first() |> decode_list_item(field, resource) end)

      _ ->
        rows
        |> List.first()
        |> List.first()
        |> decode_aggregate(kind, field, resource)
    end
  end

  # ClickHouse returns aggregate results as strings. Decode them to the
  # appropriate Elixir numeric type using the *actual* Ash attribute type of the
  # aggregated field rather than guessing from the string's shape.
  defp decode_aggregate(value, :count, _field, _resource) do
    Types.decode_value(value, %{type: :integer})
  end

  defp decode_aggregate(value, kind, field, resource)
       when kind in [:sum, :min, :max, :avg, :first] do
    case resolve_field_attr(field, resource) do
      %{} = attr ->
        # `avg` over a Decimal column would lose precision as a float; decode
        # it back to Decimal using the field's attribute type.
        Types.decode_value(value, attr)

      _ ->
        Types.decode_value(value, %{type: :float})
    end
  end

  defp decode_aggregate(value, :exists, _field, _resource) do
    Types.decode_value(value, %{type: :boolean})
  end

  defp decode_aggregate(value, _kind, _field, _resource), do: value

  # A `list` aggregate returns one value per matching row. When the aggregate
  # declares a sort, the rows arrive as `(sort key..., value)` tuples and the
  # value is the last element of the tuple.
  @spec decode_list_item(term(), term(), module()) :: term()
  defp decode_list_item(item, field, resource) when is_list(item) do
    item
    |> List.last()
    |> decode_aggregate(:first, field, resource)
  end

  defp decode_list_item(item, field, resource) do
    decode_aggregate(item, :first, field, resource)
  end

  defp default_value(aggregate), do: Map.get(aggregate, :default_value)

  defp resolve_field_attr(nil, _resource), do: nil
  defp resolve_field_attr(%{name: name}, resource), do: resolve_field_attr(name, resource)

  defp resolve_field_attr(field, resource) when is_atom(field) do
    Enum.find(Info.attributes(resource), &(&1.name == field))
  end

  defp resolve_field_attr(_field, _resource), do: nil

  # --- batched relationship aggregates --------------------------------------

  defp pk_lookup_key(record, pkey) do
    pkey
    |> Enum.map(&Map.get(record, &1))
    |> case do
      [single] -> single
      multi -> List.to_tuple(multi)
    end
  end

  # Returns `%{pk_value_or_tuple => decoded_aggregate_value}` for every record's
  # owning key, computed with a single grouped query instead of N individual
  # ones.
  defp batched_values(aggregate, records, pkey, resource, repo, opts, uuid_fields) do
    %{relationship_path: path} = aggregate

    context = %{
      resource: resource,
      repo: repo,
      opts: opts,
      uuid_fields: uuid_fields
    }

    case path do
      [] ->
        batched_same_table(aggregate, pkey, records, context)

      [rel_name] ->
        batched_related(aggregate, rel_name, pkey, records, context)

      _ ->
        # Multi-hop relationship aggregates are not supported; fall back to each
        # aggregate's `default_value`.
        %{}
    end
  end

  # Aggregating a field on the same row as the record itself — batch as a single
  # SELECT ... WHERE pk IN (...), keyed by pk.
  defp batched_same_table(aggregate, pkey, records, context) do
    %{kind: kind, field: field} = aggregate
    %{resource: resource} = context

    if length(pkey) != 1 do
      %{}
    else
      [pk_col] = pkey
      pk_values = Enum.map(records, &Map.get(&1, pk_col)) |> Enum.uniq()

      run_grouped_aggregate(aggregate, context, %{
        table: DataLayer.qualified_table(resource),
        related: resource,
        key_col: pk_col,
        fk_attr: pk_col,
        source_values: pk_values,
        kind: kind,
        field: field,
        pkey: pkey,
        records: records
      })
    end
  end

  # Aggregating a field on a related table (has_many/has_one/belongs_to) — batch
  # as a single SELECT ... GROUP BY fk, keyed by the *source* record's join
  # column value.
  defp batched_related(aggregate, rel_name, pkey, records, context) do
    %{kind: kind, field: field} = aggregate
    %{resource: resource} = context

    relationship = Info.relationship(resource, rel_name)
    related = Info.related(resource, [rel_name])

    case relationship.type do
      :belongs_to ->
        case pk(Info.primary_key(related)) do
          nil ->
            %{}

          dest_pk ->
            source_values =
              Enum.map(records, &Map.get(&1, relationship.source_attribute)) |> Enum.uniq()

            run_grouped_aggregate(aggregate, context, %{
              table: DataLayer.qualified_table(related),
              related: related,
              key_col: dest_pk,
              fk_attr: relationship.source_attribute,
              source_values: source_values,
              kind: kind,
              field: field,
              pkey: pkey,
              records: records
            })
        end

      type when type in [:has_many, :has_one] ->
        source_values =
          Enum.map(records, &Map.get(&1, relationship.source_attribute)) |> Enum.uniq()

        run_grouped_aggregate(aggregate, context, %{
          table: DataLayer.qualified_table(related),
          related: related,
          key_col: relationship.destination_attribute,
          fk_attr: relationship.source_attribute,
          source_values: source_values,
          kind: kind,
          field: field,
          pkey: pkey,
          records: records
        })

      _ ->
        %{}
    end
  end

  # Runs the grouped aggregate query over a table, keyed by the column the
  # group belongs to, and folds the rows into the map the caller merges into
  # the records.
  defp run_grouped_aggregate(aggregate, context, params) do
    %{
      table: table,
      related: related,
      key_col: key_col,
      fk_attr: fk_attr,
      source_values: source_values,
      kind: kind,
      field: field,
      pkey: pkey,
      records: records
    } = params

    %{resource: resource, uuid_fields: uuid_fields} = context

    cql_field = cql_field(kind, field, related, aggregate)

    {in_clause, in_params} = build_in_clause(key_col, source_values, uuid_fields)

    {where_clause, where_params} =
      merge_aggregate_filters(aggregate, resource, related, in_clause, in_params)

    query =
      "SELECT #{Identifier.quote_name(key_col)}, #{cql_field} FROM #{table} " <>
        "WHERE #{where_clause} GROUP BY #{Identifier.quote_name(key_col)}"

    handle_batched(query, where_params, context, %{
      kind: kind,
      field: field,
      related: related,
      fk_attr: fk_attr,
      key_col: key_col,
      default_value: default_value(aggregate),
      pkey: pkey,
      records: records
    })
  end

  # Runs a batched aggregate SELECT and folds the rows into a map keyed by the
  # source record's `pkey` lookup key. Returns `%{}` when the query fails.
  defp handle_batched(query, params, %{repo: repo, opts: opts, uuid_fields: uuid_fields}, %{
         kind: kind,
         field: field,
         related: related,
         fk_attr: fk_attr,
         key_col: key_col,
         default_value: default_value,
         pkey: pkey,
         records: records
       }) do
    case repo.query(query, params, opts) do
      {:ok, %ClickHouse.Result{rows: rows}} ->
        source_map =
          Map.new(rows, fn [key_val, value] ->
            {normalize_key(key_val, key_col, uuid_fields),
             decode_aggregate(value, kind, field, related)}
          end)

        Map.new(records, fn record ->
          fk = Map.get(record, fk_attr)
          {pk_lookup_key(record, pkey), Map.get(source_map, fk, default_value)}
        end)

      {:error, reason} ->
        warn_failed(aggregate_display(kind, field), related, reason)
        %{}
    end
  end

  # Normalizes a key returned by ClickHouse (e.g. a UUID column comes back as a
  # 16-byte binary) to the form used by decoded Ash records (UUIDs are decoded
  # to their canonical 36-character string), so batched results merge correctly.
  defp normalize_key(value, column, uuid_fields) do
    if column in uuid_fields and is_binary(value) and byte_size(value) == 16 do
      case Types.uuid_binary_to_string(value) do
        {:ok, string} -> string
        _ -> value
      end
    else
      value
    end
  end

  defp build_in_clause(col, values, uuid_fields) do
    placeholders = Enum.map_join(values, ", ", fn _ -> "?" end)
    params = Enum.map(values, &Types.convert_uuid_param(&1, col, uuid_fields))
    {"#{Identifier.quote_name(col)} IN (#{placeholders})", params}
  end

  defp pk([single]), do: single
  defp pk(_), do: nil

  # --- aggregate expressions ---------------------------------------------------

  # The SQL expression that computes the aggregate over a group of rows.
  @spec cql_field(atom(), term(), module(), map()) :: String.t()
  defp cql_field(:count, nil, _resource, _aggregate), do: "COUNT(*)"

  defp cql_field(:count, field, resource, _aggregate) do
    "COUNT(#{resolve_aggregate_field(field, resource)})"
  end

  defp cql_field(kind, field, resource, _aggregate)
       when kind in [:sum, :avg, :min, :max] do
    "#{String.upcase(to_string(kind))}(#{resolve_aggregate_field(field, resource)})"
  end

  defp cql_field(:first, field, resource, aggregate) do
    cql_field = resolve_aggregate_field(field, resource)

    case aggregate_sort(aggregate) do
      [] ->
        "any(#{cql_field})"

      [{column, :desc}] ->
        "argMax(#{cql_field}, #{Identifier.quote_name(column)})"

      [{column, _direction}] ->
        "argMin(#{cql_field}, #{Identifier.quote_name(column)})"

      columns ->
        keys = Enum.map_join(columns, ", ", fn {column, _} -> Identifier.quote_name(column) end)
        "argMin(#{cql_field}, (#{keys}))"
    end
  end

  defp cql_field(:list, field, resource, aggregate) do
    cql_field = resolve_aggregate_field(field, resource)

    case aggregate_sort(aggregate) do
      [] ->
        "groupArray(#{cql_field})"

      columns ->
        keys = Enum.map(columns, fn {column, _} -> Identifier.quote_name(column) end)
        tuple = Enum.join(keys ++ [cql_field], ", ")
        lambda = "x -> (#{Enum.map_join(1..length(keys), ", ", &"x.#{&1}")})"
        sorted = "arraySort(#{lambda}, groupArray((#{tuple})))"

        if Enum.any?(columns, &match?({_column, :desc}, &1)) do
          "arrayReverse(#{sorted})"
        else
          sorted
        end
    end
  end

  defp cql_field(:exists, _field, _resource, _aggregate), do: "COUNT(*) > 0"

  # Any other kind is rendered as a same-named ClickHouse aggregate function;
  # the value is reported as the database returned it.
  defp cql_field(kind, field, resource, _aggregate) do
    "#{String.upcase(to_string(kind))}(#{resolve_aggregate_field(field, resource)})"
  end

  # --- aggregate SELECTs -----------------------------------------------------

  defp build_aggregate_query(aggregate, table, where_clause, where_params, resource) do
    kind = Map.get(aggregate, :kind)
    field = Map.get(aggregate, :field)
    related = aggregate_resource(aggregate, resource)

    {where_clause, params} =
      merge_aggregate_filters(aggregate, resource, related, where_clause, where_params)

    cql_field = resolve_aggregate_field(field, related)
    order_clause = QueryBuilder.order_clause(aggregate_sort(aggregate))

    case kind do
      :count when is_nil(field) ->
        {"SELECT COUNT(*) FROM #{table}#{where_clause}", params}

      :count ->
        {"SELECT COUNT(#{cql_field}) FROM #{table}#{where_clause}", params}

      kind when kind in [:sum, :avg, :min, :max] ->
        {"SELECT #{String.upcase(to_string(kind))}(#{cql_field}) FROM #{table}#{where_clause}",
         params}

      :first ->
        {"SELECT #{cql_field} FROM #{table}#{where_clause}#{order_clause} LIMIT 1", params}

      :list ->
        {"SELECT #{cql_field} FROM #{table}#{where_clause}#{order_clause}", params}

      :exists ->
        {"SELECT 1 FROM #{table}#{where_clause} LIMIT 1", params}

      kind ->
        {:error, "Aggregate kind #{kind} is not supported by ClickHouse data layer"}
    end
  end

  # The resource an aggregate is computed over: the aggregated resource for a
  # relationship aggregate, the queried resource otherwise.
  @spec aggregate_resource(map(), module()) :: module()
  defp aggregate_resource(%{related?: false, resource: resource}, _source)
       when not is_nil(resource),
       do: resource

  defp aggregate_resource(aggregate, source) do
    case Map.get(aggregate, :relationship_path) do
      [] ->
        source

      path ->
        Info.related(source, path) || source
    end
  end

  # The aggregate's own filter and join filters, translated against the
  # resource the aggregate is computed over and combined with the query's own
  # WHERE clause.
  @spec merge_aggregate_filters(map(), module(), module(), String.t(), list()) ::
          {String.t(), list()}
  defp merge_aggregate_filters(aggregate, source, related, where_clause, where_params) do
    Enum.reduce(
      aggregate_filter_clauses(aggregate, source, related),
      {where_clause, where_params},
      fn clause, {where_clause, params} ->
        QueryBuilder.merge_where_clauses({where_clause, params}, clause)
      end
    )
  end

  @spec aggregate_filter_clauses(map(), module(), module()) :: [{String.t(), list()}]
  defp aggregate_filter_clauses(aggregate, source, related) do
    own = aggregate_filter(aggregate, related)
    joins = join_filter_clauses(aggregate, source, related)

    case own do
      nil -> joins
      clause -> [clause | joins]
    end
  end

  # The aggregate's own filter, translated against the aggregated resource.
  #
  # An aggregate with no filter of its own carries the expression `true` — a
  # filter that matches every row — so there is nothing to express.
  @spec aggregate_filter(map(), module()) :: {String.t(), list()} | nil
  defp aggregate_filter(aggregate, related) do
    case aggregate_query(aggregate) do
      %Ash.Query{filter: %Ash.Filter{expression: expression}}
      when not is_nil(expression) and expression != true ->
        QueryBuilder.build_where_clause([expression], related)

      _ ->
        nil
    end
  end

  # The aggregate's join filters, each translated against the resource its
  # relationship path reaches.
  @spec join_filter_clauses(map(), module(), module()) :: [{String.t(), list()}]
  defp join_filter_clauses(aggregate, source, related) do
    aggregate
    |> Map.get(:join_filters)
    |> case do
      filters when is_map(filters) ->
        Enum.map(filters, fn {path, filter} ->
          resource = join_filter_resource(source, path, related)
          translate_filter(filter, resource)
        end)

      _ ->
        []
    end
    |> Enum.reject(&is_nil/1)
  end

  defp join_filter_resource(source, path, related) do
    case List.wrap(path) do
      [] -> related
      path -> Info.related(source, path) || related
    end
  end

  @spec translate_filter(term(), module()) :: {String.t(), list()} | nil
  defp translate_filter(%Ash.Filter{expression: expression}, resource)
       when not is_nil(expression) do
    QueryBuilder.build_where_clause([expression], resource)
  end

  defp translate_filter(_filter, _resource), do: nil

  # The aggregate's own query, which carries its filter and sort.
  @spec aggregate_query(map()) :: Ash.Query.t() | nil
  defp aggregate_query(aggregate) do
    case Map.get(aggregate, :query) do
      %Ash.Query{} = query -> query
      _ -> nil
    end
  end

  # The aggregate's own sort, as a list of `{field, direction}` pairs.
  @spec aggregate_sort(map()) :: [{atom(), atom()}]
  defp aggregate_sort(aggregate) do
    case aggregate_query(aggregate) do
      %Ash.Query{sort: sort} when is_list(sort) ->
        Enum.flat_map(sort, fn
          {field, direction} when is_atom(field) -> [{field, direction}]
          field when is_atom(field) -> [{field, :asc}]
          _other -> []
        end)

      _ ->
        []
    end
  end

  defp resolve_aggregate_field(nil, _resource), do: "*"

  defp resolve_aggregate_field(field, _resource) when is_atom(field),
    do: Identifier.quote_name(field)

  defp resolve_aggregate_field(%{name: name}, _resource), do: Identifier.quote_name(name)
  defp resolve_aggregate_field(field, _resource), do: Identifier.quote_name(field)

  defp aggregate_display(kind, field) do
    "#{kind}(#{inspect(field)})"
  end

  # When `true`, a failed batched relationship-aggregate query raises instead of
  # silently falling back to each aggregate's `default_value`. Wrong numbers in
  # reports are usually worse than a loud error, so this defaults to `true`.
  # Configure via `config :ash_clickhouse, :raise_on_aggregate_failure, false`.
  @spec raise_on_aggregate_failure?() :: boolean()
  defp raise_on_aggregate_failure? do
    Application.get_env(:ash_clickhouse, :raise_on_aggregate_failure, true)
  end

  defp warn_failed(aggregate, resource, reason) do
    message =
      "Batched aggregate #{aggregate} failed for #{inspect(resource)}: " <>
        "#{Exception.message(reason)}"

    if raise_on_aggregate_failure?() do
      raise AshClickhouse.Error.QueryError, message
    else
      Logger.warning(message <> "; falling back to default_value")
    end
  end
end
