defmodule AshClickhouse.DataLayer.Aggregate do
  @moduledoc """
  SQL construction, execution, and in-memory attachment of Ash aggregates.

  Extracted from `AshClickhouse.DataLayer` so the aggregate behaviour (native
  `COUNT/SUM/AVG/MIN/MAX` queries plus batched relationship aggregates) lives in
  one focused module. Relationship aggregates are computed with one grouped query
  per aggregate across the whole result set rather than one query per record.
  """

  require Logger

  alias Ash.Resource.Info
  alias AshClickhouse.DataLayer
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
      case build_aggregate_query(aggregate, qualified, where_clause) do
        {:error, reason} ->
          {:halt, {:error, reason}}

        {query, _params} ->
          run_one(resource, repo, query, where_params, acc, aggregate)
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

    aggregate_maps =
      Map.new(aggregates, fn aggregate ->
        {aggregate.name, batched_values(aggregate, records, pkey, resource, repo, opts)}
      end)

    Enum.map(records, fn record ->
      pk_key = pk_lookup_key(record, pkey)

      agg_values =
        Map.new(aggregates, fn aggregate ->
          values = Map.fetch!(aggregate_maps, aggregate.name)
          {aggregate.name, Map.get(values, pk_key, aggregate.default_value)}
        end)

      Map.update!(record, :aggregates, &Map.merge(&1, agg_values))
    end)
  end

  # --- individual aggregate execution ---------------------------------------

  defp run_one(resource, repo, query, params, acc, aggregate) do
    opts = DataLayer.build_opts(resource)

    case repo.query(query, params, opts) do
      {:ok, %ClickHouse.Result{rows: [[value]]}} ->
        {:cont,
         Map.put(
           acc,
           aggregate.name,
           decode_aggregate(value, aggregate.kind, aggregate.field, resource)
         )}

      {:ok, %ClickHouse.Result{rows: []}} ->
        {:cont, Map.put(acc, aggregate.name, Map.get(aggregate, :default_value))}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # ClickHouse returns aggregate results as strings. Decode them to the
  # appropriate Elixir numeric type using the *actual* Ash attribute type of the
  # aggregated field rather than guessing from the string's shape.
  defp decode_aggregate(value, :count, _field, _resource) do
    Types.decode_value(value, %{type: :integer})
  end

  defp decode_aggregate(value, kind, field, resource) when kind in [:sum, :min, :max, :avg] do
    case resolve_field_attr(field, resource) do
      %{} = attr when kind != :avg ->
        Types.decode_value(value, attr)

      _ ->
        Types.decode_value(value, %{type: :float})
    end
  end

  defp decode_aggregate(value, _kind, _field, _resource), do: value

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
  defp batched_values(aggregate, records, pkey, resource, repo, opts) do
    %{kind: kind, field: field, relationship_path: path} = aggregate

    case path do
      [] ->
        batched_same_table(kind, field, pkey, records, resource, repo, opts)

      [rel_name] ->
        batched_related(aggregate, rel_name, pkey, records, resource, repo, opts)

      _ ->
        # Multi-hop relationship aggregates are not supported; fall back to each
        # aggregate's `default_value`.
        %{}
    end
  end

  # Aggregating a field on the same row as the record itself — batch as a single
  # SELECT ... WHERE pk IN (...), keyed by pk.
  defp batched_same_table(kind, field, pkey, records, resource, repo, opts) do
    if length(pkey) != 1 do
      %{}
    else
      [pk_col] = pkey
      pk_values = Enum.map(records, &Map.get(&1, pk_col)) |> Enum.uniq()
      table = DataLayer.qualified_table(resource)
      cql_field = cql_field(kind, field, resource)

      {in_clause, in_params} = build_in_clause(pk_col, pk_values, resource)

      query =
        "SELECT #{Identifier.quote_name(pk_col)}, #{cql_field} FROM #{table} WHERE #{in_clause}"

      case repo.query(query, in_params, opts) do
        {:ok, %ClickHouse.Result{rows: rows}} ->
          Map.new(rows, fn [pk, value] ->
            {normalize_key(pk, pk_col, resource), decode_aggregate(value, kind, field, resource)}
          end)

        {:error, reason} ->
          warn_failed(aggregate_display(kind, field), resource, reason)
          %{}
      end
    end
  end

  # Aggregating a field on a related table (has_many/has_one/belongs_to) — batch
  # as a single SELECT ... GROUP BY fk, keyed by the *source* record's join
  # column value.
  defp batched_related(aggregate, rel_name, pkey, records, resource, repo, opts) do
    %{kind: kind, field: field, default_value: default_value} = aggregate
    relationship = Info.relationship(resource, rel_name)
    related = Info.related(resource, [rel_name])
    related_table = DataLayer.qualified_table(related)

    case relationship.type do
      :belongs_to ->
        fk_values = Enum.map(records, &Map.get(&1, relationship.source_attribute)) |> Enum.uniq()

        case pk(Info.primary_key(related)) do
          nil ->
            %{}

          dest_pk ->
            cql_field = cql_field(kind, field, related)
            {in_clause, in_params} = build_in_clause(dest_pk, fk_values, related)

            query =
              "SELECT #{Identifier.quote_name(dest_pk)}, #{cql_field} FROM #{related_table} WHERE #{in_clause}"

            context = %{
              kind: kind,
              field: field,
              related: related,
              fk_attr: relationship.source_attribute,
              key_col: dest_pk,
              default_value: default_value,
              pkey: pkey,
              records: records
            }

            handle_batched(repo, opts, query, in_params, context)
        end

      type when type in [:has_many, :has_one] ->
        dest_fk = relationship.destination_attribute

        source_values =
          Enum.map(records, &Map.get(&1, relationship.source_attribute)) |> Enum.uniq()

        cql_field = cql_field(kind, field, related)
        {in_clause, in_params} = build_in_clause(dest_fk, source_values, related)

        query =
          "SELECT #{Identifier.quote_name(dest_fk)}, #{cql_field} FROM #{related_table} " <>
            "WHERE #{in_clause} GROUP BY #{Identifier.quote_name(dest_fk)}"

        context = %{
          kind: kind,
          field: field,
          related: related,
          fk_attr: relationship.source_attribute,
          key_col: dest_fk,
          default_value: default_value,
          pkey: pkey,
          records: records
        }

        handle_batched(repo, opts, query, in_params, context)

      _ ->
        %{}
    end
  end

  # Runs a batched aggregate SELECT and folds the rows into a map keyed by the
  # source record's `pkey` lookup key. Returns `%{}` when the query fails.
  defp handle_batched(repo, opts, query, params, %{
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
            {normalize_key(key_val, key_col, related),
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
  defp normalize_key(value, column, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)

    if column in uuid_fields and is_binary(value) and byte_size(value) == 16 do
      case Types.uuid_binary_to_string(value) do
        {:ok, string} -> string
        _ -> value
      end
    else
      value
    end
  end

  defp build_in_clause(col, values, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)
    placeholders = Enum.map_join(values, ", ", fn _ -> "?" end)
    params = Enum.map(values, &Types.convert_uuid_param(&1, col, uuid_fields))
    {"#{Identifier.quote_name(col)} IN (#{placeholders})", params}
  end

  defp pk([single]), do: single
  defp pk(_), do: nil

  defp cql_field(:count, nil, _resource), do: "COUNT(*)"

  defp cql_field(kind, field, resource),
    do: "#{String.upcase(to_string(kind))}(#{resolve_aggregate_field(field, resource)})"

  # --- aggregate SELECTs -----------------------------------------------------

  defp build_aggregate_query(%{kind: :count, field: nil}, table, where_clause) do
    {IO.iodata_to_binary(["SELECT COUNT(*) FROM ", table, where_clause]), []}
  end

  defp build_aggregate_query(%{kind: :count} = aggregate, table, where_clause) do
    field = resolve_aggregate_field(aggregate.field, aggregate.resource)
    {"SELECT COUNT(#{field}) FROM #{table}#{where_clause}", []}
  end

  defp build_aggregate_query(%{kind: kind, field: field} = aggregate, table, where_clause)
       when kind in [:sum, :avg, :min, :max] do
    cql_field = resolve_aggregate_field(field, aggregate.resource)
    {"SELECT #{String.upcase(to_string(kind))}(#{cql_field}) FROM #{table}#{where_clause}", []}
  end

  defp build_aggregate_query(%{kind: kind}, _table, _where_clause) do
    {:error, "Aggregate kind #{kind} is not supported by ClickHouse data layer"}
  end

  defp resolve_aggregate_field(nil, _resource), do: "*"

  defp resolve_aggregate_field(field, _resource) when is_atom(field),
    do: Identifier.quote_name(field)

  defp resolve_aggregate_field(%{name: name}, _resource), do: Identifier.quote_name(name)
  defp resolve_aggregate_field(field, _resource), do: Identifier.quote_name(field)

  defp aggregate_display(kind, field) do
    "#{kind}(#{inspect(field)})"
  end

  defp warn_failed(aggregate, resource, reason) do
    Logger.warning(
      "Batched aggregate #{aggregate} failed for #{inspect(resource)}; falling back to " <>
        "default_value: #{Exception.message(reason)}"
    )
  end
end
