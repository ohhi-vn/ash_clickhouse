defmodule AshClickhouse.DataLayer do
  @moduledoc """
  An Ash data layer for ClickHouse.

  This data layer implements the `Ash.DataLayer` behaviour so that Ash
  resources can be backed by a ClickHouse columnar OLAP database. It uses the
  [`clickhouse`](https://hex.pm/packages/clickhouse) client under the hood.

  ## Configuration

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer

        clickhouse do
          table "my_table"
          repo MyApp.Repo
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end
      end

  ## Features Supported

  - `:create` / `:read` / `:update` / `:destroy`
  - `:filter` — full `WHERE` support
  - `:limit` / `:offset` — ClickHouse supports both natively
  - `:select` — column projection
  - `:sort` — `ORDER BY`
  - `:distinct` — `SELECT DISTINCT`
  - `:multitenancy` — database- or attribute-based
  - `:bulk_create` — batch `INSERT`
  - `:update_query` / `:destroy_query` — `ALTER TABLE ... UPDATE/DELETE`
  - `:calculate` — in-memory calculations
  - `:composite_primary_key`
  - `:nested_expressions` / `:boolean_filter`
  - `:async_engine`
  - `:expression_calculation`
  - `{:aggregate, :count | :sum | :avg | :min | :max}` — native aggregates
  - `{:query_aggregate, :count | :sum | :avg | :min | :max}`
  - Combination queries (UNION/INTERSECT) — executed by Ash in memory

  ## Features NOT Supported

  - `:transact` — ClickHouse has no multi-statement transactions
  - `:lock` — locking is a no-op
  - `:keyset` — ClickHouse has no token-based keyset pagination
  - `:upsert` — ClickHouse has no `ON CONFLICT` (use `:create` + `:update_query`)
  - `:expression_calculation_sort` — not supported
  - `:aggregate_filter` / `:aggregate_sort` — not supported
  - `:update_many` — use `:update_query`
  - `:composite_type` / `:through_relationship`
  - `:join` — JOINs are not yet implemented
  - `:filter_relationship` / `{:exists, :unrelated}` / `{:aggregate_relationship, _}`
  - `{:query_aggregate, :list | :first | :exists | :custom}` — only count/sum/avg/min/max
  """

  @behaviour Ash.DataLayer

  require Logger

  alias Ash.Resource.Info
  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.DataLayer.Types
  alias AshClickhouse.Identifier
  alias AshClickhouse.Query
  alias AshClickhouse.Telemetry

  @default_query_timeout 30_000
  @default_batch_size 1000
  @max_batch_size 100_000

  @supported_features MapSet.new([
                        :create,
                        :read,
                        :update,
                        :destroy,
                        :filter,
                        :limit,
                        :offset,
                        :select,
                        :sort,
                        :distinct,
                        :multitenancy,
                        :bulk_create,
                        :update_query,
                        :destroy_query,
                        :calculate,
                        :composite_primary_key,
                        :nested_expressions,
                        :boolean_filter,
                        :async_engine,
                        :changeset_filter,
                        :action_select,
                        :expression_calculation
                      ])

  @type t :: Query.t()

  # ============================================================================
  # Feature support
  # ============================================================================

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :offset), do: true
  def can?(_resource_or_dsl, {:combine, _}), do: false
  def can?(_resource_or_dsl, {:join, _}), do: false
  def can?(_resource_or_dsl, {:filter_relationship, _}), do: false
  def can?(_resource_or_dsl, {:exists, :unrelated}), do: false
  def can?(_resource_or_dsl, {:aggregate_relationship, _}), do: false
  def can?(_resource_or_dsl, {:aggregate, kind}) when kind in [:count, :sum, :avg, :min, :max],
    do: true
  def can?(_resource_or_dsl, {:aggregate, _}), do: false
  def can?(_resource_or_dsl, {:query_aggregate, kind})
      when kind in [:count, :sum, :avg, :min, :max],
      do: true
  def can?(_resource_or_dsl, {:query_aggregate, _}), do: false
  def can?(_resource_or_dsl, {:sort, _}), do: true
  def can?(_resource_or_dsl, {:filter_expr, _}), do: true
  def can?(_resource_or_dsl, :calculate), do: true
  def can?(_resource_or_dsl, :action_select), do: true
  def can?(_resource_or_dsl, :nested_expressions), do: true
  def can?(_resource_or_dsl, :async_engine), do: true
  def can?(_resource_or_dsl, :changeset_filter), do: true
  def can?(_resource_or_dsl, :composite_primary_key), do: true
  def can?(_resource_or_dsl, :boolean_filter), do: true
  def can?(_resource_or_dsl, :distinct), do: true
  def can?(_resource_or_dsl, :update_query), do: true
  def can?(_resource_or_dsl, :destroy_query), do: true
  def can?(_resource_or_dsl, :bulk_create), do: true
  def can?(_resource_or_dsl, :multitenancy), do: true
  def can?(_resource_or_dsl, :transact), do: false
  def can?(_resource_or_dsl, :lock), do: false
  def can?(_resource_or_dsl, :keyset), do: false
  def can?(_resource_or_dsl, :upsert), do: false
  def can?(_resource_or_dsl, {:atomic, _}), do: false
  def can?(_resource_or_dsl, :expression_calculation_sort), do: false
  def can?(_resource_or_dsl, :aggregate_filter), do: false
  def can?(_resource_or_dsl, :aggregate_sort), do: false
  def can?(_resource_or_dsl, :update_many), do: false
  def can?(_resource_or_dsl, :composite_type), do: false
  def can?(_resource_or_dsl, :through_relationship), do: false
  def can?(_resource_or_dsl, :bulk_create_with_partial_success), do: false
  def can?(_resource_or_dsl, :bulk_upsert_return_skipped), do: false
  def can?(_resource_or_dsl, feature) when is_atom(feature), do: MapSet.member?(@supported_features, feature)
  def can?(_resource_or_dsl, _other), do: false

  @impl Ash.DataLayer
  @spec data_layer_keyset_by_default?() :: boolean()
  def data_layer_keyset_by_default?, do: false

  @impl Ash.DataLayer
  @spec return_query(t(), Ash.Resource.t()) :: {:ok, t()}
  def return_query(data_layer_query, _resource), do: {:ok, data_layer_query}

  @impl Ash.DataLayer
  @spec resource_to_query(Ash.Resource.t(), Ash.Domain.t()) :: t()
  def resource_to_query(resource, _domain) do
    Query.new(resource)
  end

  # ============================================================================
  # CRUD
  # ============================================================================

  @impl Ash.DataLayer
  @spec create(Ash.Resource.t(), Ash.Changeset.t()) :: {:ok, Ash.Resource.t()} | {:error, term()}
  def create(resource, changeset) do
    repo = repo(resource)
    attrs = changeset_to_insert_attrs(changeset, resource)
    do_insert(attrs, resource, repo)
  end

  @impl Ash.DataLayer
  @spec update(Ash.Resource.t(), Ash.Changeset.t()) :: {:ok, Ash.Resource.t()} | {:error, term()}
  def update(resource, changeset) do
    repo = repo(resource)
    attrs = changeset_to_update_attrs(changeset, resource)
    do_update(attrs, changeset, resource, repo)
  end

  @impl Ash.DataLayer
  @spec destroy(Ash.Resource.t(), Ash.Changeset.t()) :: :ok | {:error, term()}
  def destroy(resource, changeset) do
    repo = repo(resource)
    do_delete(changeset, resource, repo)
  end

  @impl Ash.DataLayer
  @spec run_query(t(), Ash.Resource.t()) :: {:ok, [Ash.Resource.t()]} | {:error, term()}
  def run_query(data_layer_query, resource) do
    %Query{repo: repo, table: table, database: database, filters: filters, sorts: sorts} =
      data_layer_query

    {query, params} = QueryBuilder.build_optimized_query(data_layer_query)

    params = convert_uuid_params(params, resource)
    opts = build_query_opts(resource)

    Logger.debug("AshClickhouse: #{query} #{inspect(params)}")

    result =
      Telemetry.span(resource, :read, query, fn ->
        case repo.query(query, params, opts) do
          {:ok, %ClickHouse.Result{rows: rows, columns: columns}} ->
            records =
              rows
              |> Enum.map(&to_ash_record(&1, resource, columns))
              |> maybe_apply_in_memory_sort(sorts)

            records

          {:ok, _} ->
            []

          error ->
            error
        end
      end)

    case result do
      {:ok, {:ok, records}} ->
        %Query{context: context} = data_layer_query
        aggregates = Map.get(context, :aggregates, [])
        records = apply_calculations(records, context)
        records = attach_aggregates(records, aggregates, resource, repo, opts)
        {:ok, records}

      {:ok, {:error, _} = err} ->
        err

      {:error, e} ->
        handle_result({:error, e})
    end
  rescue
    e in [AshClickhouse.Error.ClickhouseError] -> reraise(e, __STACKTRACE__)
    e -> handle_result({:error, e})
  end

  defp maybe_apply_in_memory_sort(records, []), do: records
  defp maybe_apply_in_memory_sort(records, nil), do: records

  defp maybe_apply_in_memory_sort(records, sorts) when is_list(sorts) do
    Enum.sort_by(records, fn record ->
      Enum.map(sorts, fn
        {field, _} -> {Map.get(record, field) == nil, Map.get(record, field)}
        field when is_atom(field) -> {Map.get(record, field) == nil, Map.get(record, field)}
      end)
    end)
  end

  # ============================================================================
  # Optional callbacks
  # ============================================================================

  @impl Ash.DataLayer
  @spec filter(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def filter(data_layer_query, filter, _resource) do
    %Query{filters: filters} = data_layer_query
    {:ok, %{data_layer_query | filters: [filter | filters]}}
  end

  @impl Ash.DataLayer
  @spec sort(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def sort(data_layer_query, sort, _resource) do
    %Query{sorts: sorts} = data_layer_query
    {:ok, %{data_layer_query | sorts: sort ++ sorts}}
  end

  @impl Ash.DataLayer
  @spec limit(t(), pos_integer(), Ash.Resource.t()) :: {:ok, t()}
  def limit(data_layer_query, limit, _resource) do
    {:ok, %{data_layer_query | limit: limit}}
  end

  @impl Ash.DataLayer
  @spec offset(t(), non_neg_integer(), Ash.Resource.t()) :: {:ok, t()}
  def offset(data_layer_query, offset, _resource) do
    {:ok, %{data_layer_query | offset: offset}}
  end

  @impl Ash.DataLayer
  @spec select(t(), list(atom()), Ash.Resource.t()) :: {:ok, t()}
  def select(data_layer_query, select, _resource) do
    {:ok, %{data_layer_query | select: select}}
  end

  @impl Ash.DataLayer
  @spec set_tenant(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def set_tenant(resource, data_layer_query, tenant) do
    if is_nil(resource) do
      {:ok, %{data_layer_query | tenant: tenant}}
    else
      strategy = Info.multitenancy_strategy(resource)

      case strategy do
        :context ->
          {:ok, %{data_layer_query | tenant: tenant}}

        :attribute ->
          attribute = Info.multitenancy_attribute(resource)

          if attribute do
            filter(data_layer_query, %{name: attribute, op: :eq, right: %{value: tenant}}, resource)
          else
            {:ok, %{data_layer_query | tenant: tenant}}
          end

        nil ->
          {:ok, %{data_layer_query | tenant: tenant}}
      end
    end
  end

  @impl Ash.DataLayer
  @spec set_context(Ash.Resource.t(), t(), map()) :: {:ok, t()}
  def set_context(_resource, data_layer_query, context) do
    %Query{context: existing} = data_layer_query
    {:ok, %{data_layer_query | context: Map.merge(existing || %{}, context)}}
  end

  @impl Ash.DataLayer
  @spec transform_query(Ash.Query.t()) :: Ash.Query.t()
  def transform_query(query) do
    resource = query.resource
    base_filter = Dsl.base_filter(resource)

    query =
      if base_filter do
        Ash.Query.do_filter(query, base_filter)
      else
        query
      end

    default_context = Dsl.default_context(resource)

    if default_context do
      Ash.Query.set_context(query, default_context)
    else
      query
    end
  end

  @impl Ash.DataLayer
  @spec bulk_create(Ash.Resource.t(), Enumerable.t(Ash.Changeset.t()), map()) ::
          :ok | {:ok, Enumerable.t(Ash.Resource.t())} | {:error, term()}
  def bulk_create(resource, changesets, opts) do
    opts = normalize_bulk_options(opts)
    repo = repo(resource)
    qualified = qualified_table(resource)

    batch_size =
      opts
      |> Keyword.get(:batch_size, @default_batch_size)
      |> min(@max_batch_size)

    return_records? = Keyword.get(opts, :return_records?, true)

    rows =
      changesets
      |> Enum.map(fn changeset ->
        attrs = changeset_to_insert_attrs(changeset, resource)
        attrs_to_row(attrs, resource)
      end)

    result =
      rows
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while(:ok, fn chunk, _acc ->
        case repo.insert_rows(qualified, chunk) do
          {:ok, _} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    case result do
      :ok when return_records? -> {:ok, stream_bulk_records(rows, resource)}
      :ok -> {:ok, []}
      {:error, error} -> handle_result({:error, error})
    end
  end

  @impl Ash.DataLayer
  @spec update_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          {:ok, [Ash.Resource.t()]} | {:error, term()}
  def update_query(data_layer_query, changeset, _resource, _opts) do
    resource = data_layer_query.resource
    repo = repo(resource)
    qualified = qualified_table(resource)
    attrs = changeset_to_update_attrs(changeset, resource)

    {set_clauses, set_values} = build_set_clauses(attrs, resource)

    %Query{filters: filters} = data_layer_query
    {where_clause, where_params} = build_where_clause(filters, resource)

    query =
      IO.iodata_to_binary([
        "ALTER TABLE ",
        qualified,
        " UPDATE ",
        Enum.join(set_clauses, ", "),
        where_clause
      ])

    with {:ok, _} <- repo.query(query, set_values ++ where_params, build_opts(resource)) do
      run_query(data_layer_query, resource)
    end
  end

  @impl Ash.DataLayer
  @spec destroy_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          :ok | {:error, term()}
  def destroy_query(data_layer_query, _changeset, _opts, _resource) do
    resource = data_layer_query.resource
    repo = repo(resource)
    qualified = qualified_table(resource)

    %Query{filters: filters} = data_layer_query
    {where_clause, where_params} = build_where_clause(filters, resource)

    query =
      IO.iodata_to_binary([
        "ALTER TABLE ",
        qualified,
        " DELETE",
        where_clause
      ])

    with {:ok, _} <- repo.query(query, where_params, build_opts(resource)), do: :ok
  end

  @impl Ash.DataLayer
  @spec distinct(t(), list(atom()), Ash.Resource.t()) :: {:ok, t()} | {:error, term()}
  def distinct(data_layer_query, distinct_columns, _resource) do
    %Query{select: existing} = data_layer_query
    select = ((existing || []) ++ distinct_columns) |> Enum.uniq()
    {:ok, %{data_layer_query | distinct: distinct_columns, select: select}}
  end

  @impl Ash.DataLayer
  @spec lock(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def lock(data_layer_query, _lock_type, _resource), do: {:ok, data_layer_query}

  @impl Ash.DataLayer
  @spec combination_of(t(), term(), Ash.Resource.t()) :: {:ok, t()} | {:error, term()}
  def combination_of(_data_layer_query, _combination, _resource) do
    {:error,
     AshClickhouse.Error.QueryError.from_error(
       "Combination queries are executed by Ash as separate queries and combined in memory."
     )}
  end

  # ============================================================================
  # Aggregates
  # ============================================================================

  @impl Ash.DataLayer
  @spec add_aggregate(t(), Ash.Query.Aggregate.t(), Ash.Resource.t()) :: {:ok, t()}
  def add_aggregate(data_layer_query, aggregate, _resource) do
    %Query{context: context} = data_layer_query
    aggregates = Map.get(context, :aggregates, [])
    {:ok, %{data_layer_query | context: Map.put(context, :aggregates, [aggregate | aggregates])}}
  end

  @impl Ash.DataLayer
  @spec add_aggregates(t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) :: {:ok, t()}
  def add_aggregates(data_layer_query, aggregates, _resource) do
    %Query{context: context} = data_layer_query
    existing = Map.get(context, :aggregates, [])
    {:ok, %{data_layer_query | context: Map.put(context, :aggregates, aggregates ++ existing)}}
  end

  @impl Ash.DataLayer
  @spec run_aggregate_query(t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
          {:ok, map()} | {:error, term()}
  def run_aggregate_query(data_layer_query, aggregates, resource) do
    repo = repo(resource)
    qualified = qualified_table(resource)
    %Query{filters: filters} = data_layer_query
    {where_clause, where_params} = build_where_clause(filters, resource)

    results =
      Enum.reduce_while(aggregates, %{}, fn aggregate, acc ->
        case build_aggregate_query(aggregate, qualified, where_clause) do
          {:error, reason} -> {:halt, {:error, reason}}
          {query, params} -> run_one_aggregate(repo, query, where_params ++ params, acc, aggregate, resource)
        end
      end)

    case results do
      {:error, error} -> handle_result({:error, error})
      map when is_map(map) -> {:ok, map}
    end
  end

  defp run_one_aggregate(repo, query, params, acc, aggregate, resource) do
    opts = build_opts(resource)

    case repo.query(query, params, opts) do
      {:ok, %ClickHouse.Result{rows: [[value]]}} ->
        {:cont, Map.put(acc, aggregate.name, value)}

      {:ok, %ClickHouse.Result{rows: []}} ->
        {:cont, Map.put(acc, aggregate.name, Map.get(aggregate, :default_value))}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @impl Ash.DataLayer
  @spec calculate(t(), Ash.Query.Calculation.t(), Ash.Resource.t()) :: {:ok, t()}
  def calculate(data_layer_query, calculation, _resource) do
    %Query{context: context} = data_layer_query
    calculations = Map.get(context, :calculations, [])
    {:ok, %{data_layer_query | context: Map.put(context, :calculations, [calculation | calculations])}}
  end

  # ============================================================================
  # Source / repo resolution
  # ============================================================================

  @impl Ash.DataLayer
  @spec source(Ash.Resource.t()) :: String.t()
  def source(resource) do
    case Process.get({__MODULE__, :source, resource}) do
      nil ->
        resolved = resolve_table_name(resource)
        Process.put({__MODULE__, :source, resource}, resolved)
        resolved

      cached ->
        cached
    end
  rescue
    _ -> resolve_table_name(resource)
  end

  @doc false
  @spec resolve_table_name(module()) :: String.t()
  def resolve_table_name(resource) do
    case Dsl.table(resource) do
      nil ->
        segments = Module.split(resource)

        name =
          if Info.domain(resource) do
            segments
            |> Enum.take(-2)
            |> Enum.map(&Macro.underscore/1)
            |> Enum.join("_")
          else
            segments
            |> List.last()
            |> Macro.underscore()
          end

        table_attr =
          try do
            Module.get_attribute(resource, :table)
          rescue
            ArgumentError -> nil
          end

        case table_attr do
          nil -> name
          "" -> name
          table -> to_string(table)
        end

      dsl_table ->
        to_string(dsl_table)
    end
    |> Identifier.sanitize!()
  end

  @spec repo(module()) :: module()
  defp repo(resource) do
    ensure_repo_cache()

    case :ets.lookup(:ash_clickhouse_repo_cache, resource) do
      [{^resource, repo}] ->
        repo

      [] ->
        repo =
          try do
            Module.get_attribute(resource, :repo)
          rescue
            ArgumentError -> nil
          end

        repo = if is_nil(repo), do: Dsl.repo(resource), else: repo

        if is_nil(repo) do
          raise """
          No repo configured for #{inspect(resource)}.

          Add a repo to your resource's clickhouse DSL block:

              clickhouse do
                repo MyApp.Repo
                table "my_table"
              end

          The repo must use AshClickhouse.Repo.
          """
        else
          :ets.insert(:ash_clickhouse_repo_cache, {resource, repo})
          repo
        end
    end
  end

  defp ensure_repo_cache do
    case :ets.whereis(:ash_clickhouse_repo_cache) do
      :undefined -> :ets.new(:ash_clickhouse_repo_cache, [:named_table, :public, {:read_concurrency, true}])
      _ -> :ok
    end
  end

  @doc false
  @spec qualified_table(module()) :: String.t()
  def qualified_table(resource) do
    table = Identifier.sanitize!(source(resource))
    database = Dsl.database(resource)

    case database do
      nil -> table
      db -> "#{Identifier.quote_name(db)}.#{table}"
    end
  end

  # ============================================================================
  # Insert / Update / Delete
  # ============================================================================

  defp do_insert(attrs, resource, repo) do
    qualified = qualified_table(resource)
    {fields, values} = build_field_value_pairs(attrs, resource)

    query =
      IO.iodata_to_binary([
        "INSERT INTO ",
        qualified,
        " (",
        Enum.join(fields, ", "),
        ") VALUES (",
        Enum.map_join(1..length(fields), ", ", fn _ -> "?" end),
        ")"
      ])

    with {:ok, _} <- repo.query(query, values, build_opts(resource)) do
      {:ok, to_ash_record(attrs, resource)}
    end
    |> handle_result()
  end

  defp do_update(attrs, changeset, resource, repo) do
    if map_size(attrs) == 0 do
      {:ok, to_ash_record(changeset.attributes, resource)}
    else
      qualified = qualified_table(resource)
      {set_clauses, values} = build_set_clauses(attrs, resource)
      {pk_where, pk_values} = build_pk_where_clause(changeset, resource)

      query =
        IO.iodata_to_binary([
          "ALTER TABLE ",
          qualified,
          " UPDATE ",
          Enum.join(set_clauses, ", "),
          " WHERE ",
          pk_where
        ])

      case repo.query(query, values ++ pk_values, build_opts(resource)) do
        {:ok, _} -> {:ok, to_ash_record(Map.merge(changeset.attributes, attrs), resource)}
        {:error, error} -> handle_result({:error, error})
      end
    end
  end

  defp do_delete(changeset, resource, repo) do
    qualified = qualified_table(resource)
    {pk_where, pk_values} = build_pk_where_clause(changeset, resource)

    query =
      IO.iodata_to_binary([
        "ALTER TABLE ",
        qualified,
        " DELETE WHERE ",
        pk_where
      ])

    case repo.query(query, pk_values, build_opts(resource)) do
      {:ok, _} -> :ok
      {:error, error} -> handle_result({:error, error})
    end
  end

  # ============================================================================
  # Aggregates SQL
  # ============================================================================

  defp build_aggregate_query(%{kind: :count, field: nil}, table, where_clause) do
    query =
      IO.iodata_to_binary([
        "SELECT COUNT(*) FROM ",
        table,
        where_clause
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: :count} = aggregate, table, where_clause) do
    field = resolve_aggregate_field(aggregate.field, aggregate.resource)
    query = "SELECT COUNT(#{field}) FROM #{table}#{where_clause}"
    {query, []}
  end

  defp build_aggregate_query(%{kind: kind, field: field}, table, where_clause)
       when kind in [:sum, :avg, :min, :max] do
    cql_field = resolve_aggregate_field(field, aggregate_resource(nil))
    query = "SELECT #{String.upcase(to_string(kind))}(#{cql_field}) FROM #{table}#{where_clause}"
    {query, []}
  end

  defp build_aggregate_query(%{kind: kind}, _table, _where_clause) do
    {:error, "Aggregate kind #{kind} is not supported by ClickHouse data layer"}
  end

  defp aggregate_resource(_), do: nil

  defp resolve_aggregate_field(nil, _resource), do: "*"

  defp resolve_aggregate_field(field, _resource) when is_atom(field) do
    Identifier.quote_name(field)
  end

  defp resolve_aggregate_field(%{name: name}, _resource), do: Identifier.quote_name(name)
  defp resolve_aggregate_field(field, _resource), do: Identifier.quote_name(field)

  # ============================================================================
  # Relationship aggregates
  # ============================================================================

  defp attach_aggregates(records, [], _resource, _repo, _opts), do: records
  defp attach_aggregates(records, _aggregates, _resource, _repo, _opts) when is_nil(_repo), do: records

  defp attach_aggregates(records, aggregates, resource, repo, opts) do
    pkey = Info.primary_key(resource)

    Enum.map(records, fn record ->
      pk_values = Map.take(record, pkey)

      agg_values =
        Enum.reduce(aggregates, %{}, fn aggregate, acc ->
          case compute_record_aggregate(aggregate, pk_values, resource, repo, opts) do
            {:ok, value} -> Map.put(acc, aggregate.name, value)
            :error -> Map.put(acc, aggregate.name, aggregate.default_value)
          end
        end)

      Map.update!(record, :aggregates, &Map.merge(&1, agg_values))
    end)
  end

  defp compute_record_aggregate(aggregate, pk_values, resource, repo, opts) do
    %{kind: kind, field: field, relationship_path: path} = aggregate

    if path == [] do
      compute_same_table_aggregate(kind, field, resource, repo, opts, pk_values)
    else
      compute_related_table_aggregate(kind, field, path, resource, repo, opts, pk_values)
    end
  end

  defp compute_same_table_aggregate(kind, field, resource, repo, opts, pk_values) do
    table = qualified_table(resource)
    {pk_where, pk_params} = build_pk_where_from_map(pk_values, resource)
    cql_field = aggregate_field_to_cql(kind, field, resource)

    query = "SELECT #{cql_field} FROM #{table} WHERE #{pk_where}"

    case repo.query(query, pk_params, opts) do
      {:ok, %ClickHouse.Result{rows: [[value]]}} -> {:ok, value}
      _ -> :error
    end
  end

  defp compute_related_table_aggregate(kind, field, path, resource, repo, opts, pk_values) do
    related = Info.related(resource, path)
    relationship = Info.relationship(resource, List.first(path))
    related_table = qualified_table(related)

    case relationship.type do
      :belongs_to ->
        fk_value = Map.get(pk_values, relationship.source_attribute)
        dest_pkey = Info.primary_key(related)

        if length(dest_pkey) == 1 do
          [pk_col] = dest_pkey
          cql_field = aggregate_field_to_cql(kind, field, related)

          query =
            "SELECT #{cql_field} FROM #{related_table} WHERE #{Identifier.quote_name(pk_col)} = ?"

          case repo.query(query, [fk_value], opts) do
            {:ok, %ClickHouse.Result{rows: [[value]]}} -> {:ok, value}
            _ -> :error
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp aggregate_field_to_cql(:count, nil, _resource), do: "COUNT(*)"
  defp aggregate_field_to_cql(kind, field, resource), do: "#{String.upcase(to_string(kind))}(#{resolve_aggregate_field(field, resource)})"

  defp build_pk_where_from_map(pk_values, resource) do
    {clauses, values} =
      Enum.reduce(pk_values, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{Identifier.quote_name(k)} = ?" | cs], [v | vs]}
      end)

    {Enum.reverse(clauses) |> Enum.join(" AND "), :lists.reverse(values)}
  end

  # ============================================================================
  # Calculations
  # ============================================================================

  defp apply_calculations(records, %{calculations: calculations}) when is_list(calculations) do
    Enum.map(records, fn record ->
      Enum.reduce(calculations, record, fn calculation, acc ->
        case calculate_in_memory(calculation, acc) do
          {:ok, value} -> Map.put(acc, calculation.name, value)
          _ -> acc
        end
      end)
    end)
  end

  defp apply_calculations(records, _), do: records

  defp calculate_in_memory(%{module: module, opts: opts}, record) when is_atom(module) do
    if function_exported?(module, :calculate, 2) do
      {:ok, module.calculate([record], opts)}
    else
      {:error, :no_calculate_function}
    end
  end

  defp calculate_in_memory(%{expr: expr}, record) when is_function(expr), do: {:ok, expr.(record)}
  defp calculate_in_memory(_, _), do: {:error, :unsupported_calculation}

  # ============================================================================
  # SQL construction helpers
  # ============================================================================

  defp build_field_value_pairs(attrs, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)

    {fields, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {fs, vs} ->
        value =
          if uuid_field?(k, v, uuid_fields) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        {[Identifier.quote_name(to_string(k)) | fs], [value | vs]}
      end)

    {Enum.reverse(fields), :lists.reverse(values)}
  end

  defp build_set_clauses(attrs, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)

    {clauses, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {cs, vs} ->
        value =
          if uuid_field?(k, v, uuid_fields) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        {["#{Identifier.quote_name(to_string(k))} = ?" | cs], [value | vs]}
      end)

    {Enum.reverse(clauses), :lists.reverse(values)}
  end

  defp build_pk_where_clause(changeset, resource) do
    pk = get_primary_key_from_changeset(changeset, resource)
    build_where_from_map(pk, resource)
  end

  defp build_where_clause(filters, resource) when is_list(filters) do
    {clause, params} = QueryBuilder.build_where_clause(filters)
    {clause, convert_uuid_params(params, resource)}
  end

  defp build_where_clause(nil, _resource), do: {"", []}
  defp build_where_clause([], _resource), do: {"", []}

  defp build_where_from_map(pk_map, _resource) do
    {clauses, values} =
      Enum.reduce(pk_map, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{Identifier.quote_name(to_string(k))} = ?" | cs], [v | vs]}
      end)

    {Enum.reverse(clauses) |> Enum.join(" AND "), :lists.reverse(values)}
  end

  defp uuid_field?(k, v, uuid_fields) do
    is_binary(v) and (k in uuid_fields or Types.uuid_like_string?(v))
  end

  defp convert_uuid_params(params, _resource) do
    Enum.map(params, fn
      value when is_binary(value) and byte_size(value) == 36 ->
        if Types.uuid_like_string?(value) do
          case Types.uuid_string_to_binary(value) do
            {:ok, bin} -> bin
            _ -> value
          end
        else
          value
        end

      value ->
        value
    end)
  end

  # ============================================================================
  # Changeset helpers
  # ============================================================================

  defp changeset_to_insert_attrs(changeset, resource) do
    attrs = changeset.attributes

    Enum.reduce(Info.attributes(resource), attrs, fn attr, acc ->
      if attr.primary_key? and not Map.has_key?(acc, attr.name) and autogenerate_attribute?(attr) do
        Map.put(acc, attr.name, autogenerate_value(attr))
      else
        acc
      end
    end)
  end

  defp changeset_to_update_attrs(changeset, _resource), do: changeset.attributes

  defp autogenerate_value(attr) do
    cond do
      attr.type && function_exported?(attr.type, :generator, 1) ->
        constraints = Map.get(attr, :constraints, [])
        attr.type.generator(constraints) |> Enum.at(0)

      attr.type in [Ash.Type.UUID, :uuid] ->
        generate_uuid()

      true ->
        nil
    end
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    "#{format_hex(a, 8)}-#{format_hex(b, 4)}-#{format_hex(c, 4)}-#{format_hex(d, 4)}-#{format_hex(e, 12)}"
  end

  defp format_hex(value, len), do: value |> Integer.to_string(16) |> String.pad_leading(len, "0")

  defp autogenerate_attribute?(attr) do
    Map.get(attr, :autogenerate?) == true or is_function(Map.get(attr, :default))
  end

  defp get_primary_key_from_changeset(changeset, resource) do
    Enum.reduce(Info.attributes(resource), %{}, fn attr, acc ->
      if attr.primary_key? do
        case Map.get(changeset.attributes, attr.name) do
          nil -> acc
          val -> Map.put(acc, attr.name, val)
        end
      else
        acc
      end
    end)
  end

  defp attrs_to_row(attrs, _resource) do
    attrs
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  defp stream_bulk_records(rows, resource) do
    Stream.map(rows, fn row -> to_ash_record(row, resource) end)
  end

  # ============================================================================
  # Record decoding
  # ============================================================================

  defp to_ash_record(attrs, resource) when is_map(attrs) do
    to_ash_record(attrs, resource, [])
  end

  defp to_ash_record(row, resource, columns) when is_list(row) and is_list(columns) do
    record_map =
      row
      |> Enum.zip(columns)
      |> Enum.reduce(%{}, fn {value, col}, acc ->
        col_name = to_string(col)
        Map.put(acc, col_name, value)
      end)

    to_ash_record(record_map, resource)
  end

  defp to_ash_record(row, resource, _columns) when is_list(row) do
    attr_names = resource |> Info.attributes() |> Enum.map(& &1.name)
    record_map = row |> Enum.zip(attr_names) |> Enum.reduce(%{}, fn {v, k}, acc -> Map.put(acc, to_string(k), v) end)
    to_ash_record(record_map, resource)
  end

  defp to_ash_record(row, resource, _columns) when is_map(row) do
    uuid_fields = Types.uuid_attribute_names(resource)
    atom_fields = Types.atom_attribute_names(resource)

    attrs =
      resource
      |> Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        value = Map.get(row, attr.name) || Map.get(row, to_string(attr.name))

        decoded =
          cond do
            attr.name in uuid_fields and is_binary(value) and byte_size(value) == 16 ->
              case Types.uuid_binary_to_string(value) do
                {:ok, str} -> str
                _ -> value
              end

            attr.name in atom_fields and is_binary(value) ->
              String.to_atom(value)

            true ->
              value
          end

        Map.put(acc, attr.name, decoded)
      end)

    struct(resource, attrs)
  end

  # ============================================================================
  # Options / error handling
  # ============================================================================

  defp build_opts(_resource) do
    []
  end

  defp build_query_opts(_resource) do
    []
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_bulk_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_bulk_options(opts) when is_list(opts), do: opts

  defp handle_result({:ok, _} = ok), do: ok
  defp handle_result(:ok), do: :ok

  defp handle_result({:error, %mod{} = error}) when mod in [
         ClickHouse.QueryError,
         ClickHouse.ConnectionError,
         ClickHouse.DatabaseError,
         ClickHouse.ParsingError,
         ClickHouse.StreamError,
         ClickHouse.SystemError,
         ClickHouse.CoordinationError
       ] do
    Logger.warning("ClickHouse error: #{Exception.message(error)}")
    {:error, AshClickhouse.Error.wrap_clickhouse_error(error)}
  end

  defp handle_result({:error, %AshClickhouse.Error.ClickhouseError{}} = error), do: error

  defp handle_result({:error, error}) do
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, AshClickhouse.Error.wrap_clickhouse_error(error)}
  end
end
