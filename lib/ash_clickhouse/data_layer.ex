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

  ## Relationship aggregates

  `attach_aggregates/5` supports `{:aggregate, :count | :sum | :avg | :min | :max}`
  over `belongs_to`, `has_many`, and `has_one` relationships. A `belongs_to`
  aggregate is a *lookup* of the related row's scalar field (e.g.
  `customer.tier`), not a true aggregation across multiple rows — ClickHouse's
  lack of JOINs makes this distinction more visible than in a Postgres-backed
  data layer. `has_many`/`has_one` aggregates are real grouped aggregations
  (e.g. "count of orders per customer"). Multi-hop relationship paths are not
  supported and fall back to each aggregate's `default_value`.

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
  alias AshClickhouse.DataLayer.Aggregate
  alias AshClickhouse.DataLayer.Calculations
  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.DataLayer.Insert
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.DataLayer.Record
  alias AshClickhouse.Error
  alias AshClickhouse.Identifier
  alias AshClickhouse.Query
  alias AshClickhouse.Telemetry
  alias ClickHouse.Format

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
                        :stream,
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

  # `:filter_expr` and `{:sort, _}` are supported but not members of
  # `@supported_features` (the MapSet only contains bare atoms, and `can?/2`
  # dispatches tuples to the `_other` fallback). They need explicit clauses.
  # All other supported *atom* features resolve via the `@supported_features`
  # MapSet fallback below — keeping a single source of truth avoids the two
  # drifting apart.
  def can?(_resource_or_dsl, {:filter_expr, _}), do: true
  def can?(_resource_or_dsl, {:sort, _}), do: true

  # Explicitly-unsupported features that are *not* members of `@supported_features`.
  # These must stay as `false` clauses because the MapSet fallback would otherwise
  # return `false` for them anyway — but listing them keeps intent obvious and
  # lets us attach a clear `do: false` for each.
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

  def can?(_resource_or_dsl, feature) when is_atom(feature),
    do: MapSet.member?(@supported_features, feature)

  def can?(_resource_or_dsl, _other), do: false

  @impl Ash.DataLayer
  @spec data_layer_keyset_by_default?() :: boolean()
  def data_layer_keyset_by_default?, do: false

  @impl Ash.DataLayer
  @spec return_query(t(), Ash.Resource.t()) :: {:ok, t()}
  def return_query(data_layer_query, _resource), do: {:ok, data_layer_query}

  @doc """
  Returns the set of features declared as supported via `@supported_features`.

  Exposed for tests/tooling so the single source of truth for `can?/2` can be
  inspected without re-listing the features.
  """
  @spec supported_features() :: MapSet.t(atom())
  def supported_features, do: @supported_features

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
    attrs = Insert.changeset_to_insert_attrs(changeset, resource)
    do_insert(attrs, resource, repo)
  end

  @impl Ash.DataLayer
  @spec update(Ash.Resource.t(), Ash.Changeset.t()) :: {:ok, Ash.Resource.t()} | {:error, term()}
  def update(resource, changeset) do
    repo = repo(resource)
    attrs = Insert.changeset_to_update_attrs(changeset, resource)
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
    %Query{repo: repo} = data_layer_query
    repo = if is_nil(repo), do: repo(resource), else: repo
    {query, params} = QueryBuilder.build_optimized_query(data_layer_query)
    opts = []

    # NOTE: debug logging includes the full SQL and bound parameters, which may
    # contain row data. Do not enable `:debug` for this module in production
    # unless you are comfortable with that data appearing in logs.
    Logger.debug("AshClickhouse: #{query} #{inspect(params)}")

    result =
      Telemetry.span(resource, :read, query, fn ->
        case repo.query(query, params, opts) do
           {:ok, %ClickHouse.Result{rows: rows, columns: columns}} ->
             columns = columns || query_columns(data_layer_query)

             records =
               rows
              |> Enum.map(&Record.to_ash_record(&1, resource, columns))

            {:ok, records}

          {:ok, _} ->
            {:ok, []}

          {:error, _} = error ->
            error
        end
      end)

    case result do
      {:ok, records} ->
        %Query{context: context} = data_layer_query
        aggregates = Map.get(context, :aggregates, [])
        records = Calculations.apply_calculations(records, context)
        records = Aggregate.attach(records, aggregates, resource, repo, opts)
        {:ok, records}

      {:error, _} = err ->
        handle_result(err)
    end
  end

  @doc """
  Returns a stream of Ash records for the given query, consuming ClickHouse's
  native query stream instead of materializing every row into memory.

  This is the natural read path for large OLAP scans/reports. The returned
  stream yields decoded Ash records one at a time as chunks arrive.

  In-memory calculations and aggregates configured on the query are applied to
  each decoded chunk, so `stream/3` returns results identical to `run_query/2`
  (which applies them after fetching all rows). This keeps streaming and
  non-streaming reads behaviourally consistent.

  ## Options

  - `:mutations_sync` is ignored for reads.
  - any other options are forwarded to the underlying ClickHouse client.
  """
  @spec stream(t(), Ash.Resource.t(), keyword()) :: Enumerable.t(Ash.Resource.t())
  def stream(data_layer_query, resource, opts \\ []) do
    %Query{repo: repo, context: context} = data_layer_query

    {query, params} = QueryBuilder.build_optimized_query(data_layer_query)
    opts = opts

    repo = if is_nil(repo), do: repo(resource), else: repo

    # Apply the same default format used by `Connection.query` so ClickHouse
    # returns `JSONCompactEachRow` (one JSON array per row). Without this, the
    # stream would receive ClickHouse's default format (JSON objects) and
    # `JSONCompactEachRow.decode/1` would fail to parse it.
    opts = AshClickhouse.Connection.with_default_format(opts)

    # Thread the configured database into the client opts so the `clickhouse`
    # client appends it as `?database=...` (it is no longer baked into the
    # connection URL). Without this, streaming would target the default
    # database instead of the resource's database.
    opts =
      if Keyword.has_key?(opts, :database) do
        opts
      else
        database = AshClickhouse.Connection.database_for(repo)
        if database, do: [{:database, database} | opts], else: opts
      end

    aggregates = Map.get(context, :aggregates, [])

    # JSONCompactEachRow stream chunks carry no column names, so we must derive
    # the expected column order from the query itself. When `select`/`distinct`
    # is set, the SELECT list order is known and matches what
    # `build_optimized_query/1` emits; otherwise we fall back to the resource's
    # attribute declaration order (which matches tables created via this data
    # layer's migrations).
    columns = query_columns(data_layer_query)

    try do
      stream = ClickHouse.stream!(repo, query, params, opts)

      # `ClickHouse.Stream` is itself a lazy Enumerable that yields raw response
      # chunks as they arrive. We decode each chunk into Ash records and apply
      # in-memory calculations/aggregates, emitting one record at a time. The
      # underlying stream is started/advanced/halted by its own Enumerable
      # implementation, so no manual cleanup is required here.
      Stream.flat_map(stream, fn chunk ->
        {_columns, rows} = Format.JSONCompactEachRow.decode(chunk)

        rows
        |> Enum.map(&Record.to_ash_record(&1, resource, columns))
        |> Calculations.apply_calculations(context)
        |> Aggregate.attach(aggregates, resource, repo, opts)
      end)
    rescue
      e ->
        # Wrap raw client exceptions the same way every other read path does so
        # callers get a consistent `Error.ClickhouseError`.
        # Non-client exceptions (genuine bugs) are reraised with their original
        # stacktrace intact rather than being mislabelled as a client error.
        Error.reraise_or_wrap(e, __STACKTRACE__)
    end
  end

  # ============================================================================
  # Optional callbacks
  # ============================================================================

  @impl Ash.DataLayer
  @spec filter(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def filter(data_layer_query, %Ash.Filter{expression: expression}, _resource) do
    %Query{filters: filters} = data_layer_query
    {:ok, %{data_layer_query | filters: [expression | filters]}}
  end

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
            filter(
              data_layer_query,
              %{name: attribute, op: :eq, right: %{value: tenant}},
              resource
            )
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

    {fields, rows} =
      changesets
      |> Enum.map(fn changeset ->
        attrs = Insert.changeset_to_insert_attrs(changeset, resource)
        Insert.attrs_to_row(attrs, resource)
      end)
      |> Insert.build_insert_rows(resource)

    insert_opts = Insert.insert_opts(resource, opts)

    statement = Insert.insert_statement(qualified, fields)

    result =
      rows
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while(:ok, fn chunk, _acc ->
        case repo.insert_rows(qualified, statement, chunk, insert_opts) do
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
    attrs = Insert.changeset_to_update_attrs(changeset, resource)

    {set_clauses, set_values} = Insert.build_set_clauses(attrs, resource)

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

    with {:ok, _} <-
           repo.query(
             query,
             set_values ++ where_params,
             build_opts(resource, changeset.context, 1)
           ) do
      run_query(data_layer_query, resource)
    end
  end

  @impl Ash.DataLayer
  @spec destroy_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          :ok | {:error, term()}
  def destroy_query(data_layer_query, changeset, _opts, _resource) do
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

    with {:ok, _} <-
           repo.query(query, where_params, build_opts(resource, changeset.context, 1)),
         do: :ok
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

  # Combination queries (UNION/INTERSECT) are executed by Ash as separate
  # queries and combined in memory, so Ash never invokes this callback for the
  # ClickHouse data layer. `can?/2` reports `{:combine, _}` as unsupported.
  # This clause is defensive/unreachable and exists only to satisfy the
  # `Ash.DataLayer` behaviour.
  @impl Ash.DataLayer
  @spec combination_of(t(), term(), Ash.Resource.t()) :: {:ok, t()} | {:error, term()}
  def combination_of(_data_layer_query, _combination, _resource) do
    {:error,
     Error.QueryError.from_error(
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

    case Aggregate.run(aggregates, resource, repo, qualified, where_clause, where_params) do
      {:error, error} -> handle_result({:error, error})
      map when is_map(map) -> {:ok, map}
    end
  end

  @impl Ash.DataLayer
  @spec calculate(t(), Ash.Query.Calculation.t(), Ash.Resource.t()) :: {:ok, t()}
  def calculate(data_layer_query, calculation, _resource) do
    %Query{context: context} = data_layer_query
    calculations = Map.get(context, :calculations, [])

    {:ok,
     %{data_layer_query | context: Map.put(context, :calculations, [calculation | calculations])}}
  end

  # ============================================================================
  # Source / repo resolution
  # ============================================================================

  @impl Ash.DataLayer
  @spec source(Ash.Resource.t()) :: String.t()
  def source(resource) do
    resolve_table_name(resource)
  end

  @doc false
  @spec resolve_table_name(module()) :: String.t()
  def resolve_table_name(resource) do
    case Dsl.table(resource) do
      nil ->
        segments = Module.split(resource)

        name =
          case safe_domain(resource) do
            nil ->
              segments
              |> List.last()
              |> Macro.underscore()

            _domain ->
              segments
              |> Enum.take(-2)
              |> Enum.map_join("_", &Macro.underscore/1)
          end

        Identifier.sanitize!(name)

      table ->
        Identifier.sanitize!(to_string(table))
    end
  end

  # `Ash.Resource.Info.domain/1` can raise (e.g. "not a Spark DSL module")
  # for resources whose domain isn't persisted as a DSL field. Guard it so a
  # missing domain degrades gracefully to the module-name-derived default
  # table name instead of crashing source/table resolution.
  defp safe_domain(resource) do
    Info.domain(resource)
  rescue
    _ -> nil
  end

  @spec repo(module()) :: module()
  def repo(resource) do
    ensure_repo_cache()

    case :ets.lookup(:ash_clickhouse_repo_cache, resource) do
      [{^resource, repo}] ->
        repo

      [] ->
        repo = Dsl.repo(resource)

        if is_nil(repo) do
          raise Error.ConfigurationError, """
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

  @doc """
  Clears the resource → repo ETS cache.

  The cache is populated lazily and lives for the life of the VM, which is
  correct for long-running production apps but painful for test suites that
  redefine resources or repo configuration between tests. Call this from
  `setup`/`on_exit` in those tests to force re-resolution.
  """
  @spec clear_repo_cache!() :: :ok
  def clear_repo_cache! do
    :ets.delete_all_objects(:ash_clickhouse_repo_cache)
    :ok
  end

  defp ensure_repo_cache do
    case :ets.whereis(:ash_clickhouse_repo_cache) do
      :undefined ->
        try do
          :ets.new(:ash_clickhouse_repo_cache, [:named_table, :public, {:read_concurrency, true}])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc false
  @spec qualified_table(module()) :: String.t()
  def qualified_table(resource) do
    table = Identifier.sanitize!(source(resource))
    database = Dsl.database(resource)

    case database do
      nil -> Identifier.quote_name(table)
      db -> "#{Identifier.quote_name(db)}.#{Identifier.quote_name(table)}"
    end
  end

  # ============================================================================
  # Insert / Update / Delete
  # ============================================================================

  defp do_insert(attrs, resource, repo) do
    qualified = qualified_table(resource)
    {fields, rows} = Insert.build_insert_rows([Insert.attrs_to_row(attrs, resource)], resource)
    statement = Insert.insert_statement(qualified, fields)
    insert_opts = Insert.insert_opts(resource, [])

    with {:ok, _} <- repo.insert_rows(qualified, statement, rows, insert_opts) do
      {:ok, Record.to_ash_record(attrs, resource)}
    end
    |> handle_result()
  end

  defp do_update(attrs, changeset, resource, repo) do
    if map_size(attrs) == 0 do
      {:ok, Record.to_ash_record(changeset.data, resource)}
    else
      qualified = qualified_table(resource)
      {set_clauses, values} = Insert.build_set_clauses(attrs, resource)
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
        {:ok, _} -> {:ok, Record.to_ash_record(Map.merge(changeset.data, attrs), resource)}
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
  # SQL construction helpers
  # ============================================================================

  defp build_pk_where_clause(changeset, resource) do
    pk = Insert.get_primary_key_from_changeset(changeset, resource)
    Insert.build_where_from_map(pk, resource)
  end

  defp build_where_clause(filters, resource) when is_list(filters) do
    QueryBuilder.build_where_clause(filters, resource)
  end

  defp build_where_clause(nil, _resource), do: {"", []}
  defp build_where_clause([], _resource), do: {"", []}

  # ============================================================================
  # Record decoding
  # ============================================================================

  defp stream_bulk_records(rows, resource) do
    Stream.map(rows, &Record.to_ash_record(&1, resource))
  end

  # Derives the expected column order for the streaming decode path from the
  # query itself (see `stream/3`). Returns `nil` to fall back to the resource's
  # attribute declaration order when the query selects the whole row.
  defp query_columns(%Query{select: select}) when is_list(select) and select != [],
    do: select

  defp query_columns(%Query{distinct: distinct}) when is_list(distinct) and distinct != [],
    do: distinct

  defp query_columns(_), do: nil

  # Options / error handling
  # ============================================================================

  @doc false
  def build_opts(resource), do: build_opts(resource, nil)

  # Builds the option list forwarded to a query. When the caller passes a
  # context containing `mutations_sync`, it is forwarded as ClickHouse's
  # `mutations_sync` query setting so ALTER TABLE ... UPDATE/DELETE waits for
  # the mutation to complete (1 = current replica, 2 = all replicas) before the
  # subsequent read. This gives callers read-your-writes semantics for
  # update_query/destroy_query when they opt in; the default is async.
  defp build_opts(resource, context, default_sync \\ nil) do
    context = if is_map(context), do: context, else: %{}

    from_context =
      Map.get(context, :mutations_sync) || Map.get(context, :private, %{})[:mutations_sync]

    sync =
      if from_context != nil, do: from_context, else: Dsl.mutations_sync(resource) || default_sync

    if sync != nil do
      [settings: %{mutations_sync: sync}]
    else
      []
    end
  end

  defp normalize_bulk_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_bulk_options(opts) when is_list(opts), do: opts

  defp handle_result({:ok, _} = ok), do: ok
  defp handle_result(:ok), do: :ok

  # Already-wrapped errors pass through unchanged.
  defp handle_result({:error, %Error.ClickhouseError{}} = error), do: error

  defp handle_result({:error, error}) do
    if Error.client_error?(error) do
      Logger.warning("ClickHouse error: #{Exception.message(error)}")
      {:error, Error.wrap_clickhouse_error(error)}
    else
      Logger.error("Unexpected error: #{inspect(error)}")
      {:error, Error.wrap_clickhouse_error(error)}
    end
  end
end
