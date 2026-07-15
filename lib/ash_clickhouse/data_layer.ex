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
  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.DataLayer.Types
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
    %Query{repo: repo} = data_layer_query
    repo = if is_nil(repo), do: repo(resource), else: repo
    {query, params} = QueryBuilder.build_optimized_query(data_layer_query)

    opts = build_query_opts(resource)

    # NOTE: debug logging includes the full SQL and bound parameters, which may
    # contain row data. Do not enable `:debug` for this module in production
    # unless you are comfortable with that data appearing in logs.
    Logger.debug("AshClickhouse: #{query} #{inspect(params)}")

    result =
      Telemetry.span(resource, :read, query, fn ->
        case repo.query(query, params, opts) do
          {:ok, %ClickHouse.Result{rows: rows, columns: columns}} ->
            records =
              rows
              |> Enum.map(&to_ash_record(&1, resource, columns))

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
        records = apply_calculations(records, context)
        records = attach_aggregates(records, aggregates, resource, repo, opts)
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
    opts = build_query_opts(resource) ++ opts

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
        |> Enum.map(&to_ash_record(&1, resource))
        |> apply_calculations(context)
        |> attach_aggregates(aggregates, resource, repo, opts)
      end)
    rescue
      e ->
        # Wrap raw client exceptions the same way every other read path does so
        # callers get a consistent `AshClickhouse.Error.ClickhouseError`.
        raise AshClickhouse.Error.wrap_clickhouse_error(e)
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
        attrs = changeset_to_insert_attrs(changeset, resource)
        attrs_to_row(attrs, resource)
      end)
      |> build_insert_rows(resource)

    insert_opts = build_insert_opts(resource, opts)

    statement =
      IO.iodata_to_binary([
        "INSERT INTO ",
        qualified,
        " (",
        Enum.join(fields, ", "),
        ") FORMAT JSONCompactEachRow"
      ])

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
          {:error, reason} ->
            {:halt, {:error, reason}}

          {query, params} ->
            run_one_aggregate(repo, query, where_params ++ params, acc, aggregate, resource)
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
  # aggregated field rather than guessing from the string's shape (the old
  # `String.contains?(value, ".")` sniffing mishandled scientific notation and
  # silently downgraded `Decimal` columns to `float`, losing precision).
  defp decode_aggregate(value, :count, _field, _resource) do
    Types.decode_value(value, %{type: :integer})
  end

  defp decode_aggregate(value, kind, field, resource) when kind in [:sum, :min, :max, :avg] do
    case resolve_field_attr(field, resource) do
      %{} = attr when kind != :avg ->
        Types.decode_value(value, attr)

      _ ->
        # `:avg` always returns a fractional result regardless of source column
        # type; fall back to float when the field type is unknown.
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
          raise AshClickhouse.Error.ConfigurationError, """
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
    {fields, rows} = build_insert_rows([attrs_to_row(attrs, resource)], resource)

    statement =
      IO.iodata_to_binary([
        "INSERT INTO ",
        qualified,
        " (",
        Enum.join(fields, ", "),
        ") FORMAT JSONCompactEachRow"
      ])

    insert_opts = build_insert_opts(resource, [])

    with {:ok, _} <- repo.insert_rows(qualified, statement, rows, insert_opts) do
      {:ok, to_ash_record(attrs, resource)}
    end
    |> handle_result()
  end

  defp do_update(attrs, changeset, resource, repo) do
    if map_size(attrs) == 0 do
      {:ok, to_ash_record(changeset.data, resource)}
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
        {:ok, _} -> {:ok, to_ash_record(Map.merge(changeset.data, attrs), resource)}
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

  defp build_aggregate_query(%{kind: kind, field: field} = aggregate, table, where_clause)
       when kind in [:sum, :avg, :min, :max] do
    cql_field = resolve_aggregate_field(field, aggregate.resource)
    query = "SELECT #{String.upcase(to_string(kind))}(#{cql_field}) FROM #{table}#{where_clause}"
    {query, []}
  end

  defp build_aggregate_query(%{kind: kind}, _table, _where_clause) do
    {:error, "Aggregate kind #{kind} is not supported by ClickHouse data layer"}
  end

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

  defp attach_aggregates(records, _aggregates, _resource, nil, _opts), do: records

  # One batched lookup per aggregate instead of one query per (record,
  # aggregate) pair. Each aggregate is computed once across the whole result set
  # with a single grouped query, then the results are merged back into the
  # records in memory. This turns an N×M round-trip pattern (N rows × M
  # aggregates) into M round-trips regardless of page size.
  defp attach_aggregates(records, aggregates, resource, repo, opts) do
    pkey = Info.primary_key(resource)

    aggregate_maps =
      Map.new(aggregates, fn aggregate ->
        {aggregate.name, batched_aggregate_values(aggregate, records, pkey, resource, repo, opts)}
      end)

    Enum.map(records, fn record ->
      pk_key = pk_lookup_key(record, pkey)

      agg_values =
        Map.new(aggregates, fn aggregate ->
          values = Map.fetch!(aggregate_maps, aggregate.name)
          value = Map.get(values, pk_key, aggregate.default_value)
          {aggregate.name, value}
        end)

      Map.update!(record, :aggregates, &Map.merge(&1, agg_values))
    end)
  end

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
  defp batched_aggregate_values(aggregate, records, pkey, resource, repo, opts) do
    %{kind: kind, field: field, relationship_path: path, default_value: default_value} = aggregate

    case path do
      [] ->
        batched_same_table_aggregate(kind, field, pkey, records, resource, repo, opts)

      [rel_name] ->
        batched_related_aggregate(
          kind,
          field,
          rel_name,
          pkey,
          records,
          resource,
          repo,
          opts,
          default_value
        )

      _ ->
        # Multi-hop relationship aggregates are not supported; fall back to each
        # aggregate's `default_value`.
        %{}
    end
  end

  # Aggregating a field on the same row as the record itself — batch as a single
  # SELECT ... WHERE pk IN (...), keyed by pk.
  defp batched_same_table_aggregate(kind, field, pkey, records, resource, repo, opts) do
    if length(pkey) != 1 do
      %{}
    else
      [pk_col] = pkey
      pk_values = Enum.map(records, &Map.get(&1, pk_col)) |> Enum.uniq()
      table = qualified_table(resource)
      cql_field = aggregate_field_to_cql(kind, field, resource)

      {in_clause, in_params} = build_in_clause(pk_col, pk_values, resource)

      query =
        "SELECT #{Identifier.quote_name(pk_col)}, #{cql_field} FROM #{table} WHERE #{in_clause}"

      case repo.query(query, in_params, opts) do
        {:ok, %ClickHouse.Result{rows: rows}} ->
          Map.new(rows, fn [pk, value] ->
            {normalize_key(pk, pk_col, resource), decode_aggregate(value, kind, field, resource)}
          end)

        _ ->
          %{}
      end
    end
  end

  # Aggregating a field on a related table (has_many/has_one/belongs_to) — batch
  # as a single SELECT ... GROUP BY fk, keyed by the *source* record's join
  # column value.
  defp batched_related_aggregate(
         kind,
         field,
         rel_name,
         pkey,
         records,
         resource,
         repo,
         opts,
         default_value
       ) do
    relationship = Info.relationship(resource, rel_name)
    related = Info.related(resource, [rel_name])
    related_table = qualified_table(related)

    case relationship.type do
      :belongs_to ->
        fk_values = Enum.map(records, &Map.get(&1, relationship.source_attribute)) |> Enum.uniq()
        dest_pkey = Info.primary_key(related)

        if length(dest_pkey) == 1 do
          [dest_pk] = dest_pkey
          cql_field = aggregate_field_to_cql(kind, field, related)
          {in_clause, in_params} = build_in_clause(dest_pk, fk_values, related)

          query =
            "SELECT #{Identifier.quote_name(dest_pk)}, #{cql_field} FROM #{related_table} WHERE #{in_clause}"

          handle_aggregate_result(
            repo,
            query,
            in_params,
            opts,
            kind,
            field,
            related,
            relationship.source_attribute,
            pkey,
            records,
            default_value,
            dest_pk
          )
        else
          %{}
        end

      type when type in [:has_many, :has_one] ->
        dest_fk = relationship.destination_attribute

        source_values =
          Enum.map(records, &Map.get(&1, relationship.source_attribute)) |> Enum.uniq()

        cql_field = aggregate_field_to_cql(kind, field, related)
        {in_clause, in_params} = build_in_clause(dest_fk, source_values, related)

        query =
          "SELECT #{Identifier.quote_name(dest_fk)}, #{cql_field} FROM #{related_table} " <>
            "WHERE #{in_clause} GROUP BY #{Identifier.quote_name(dest_fk)}"

        handle_aggregate_result(
          repo,
          query,
          in_params,
          opts,
          kind,
          field,
          related,
          relationship.source_attribute,
          pkey,
          records,
          default_value,
          dest_fk
        )

      _ ->
        %{}
    end
  end

  # Runs a batched aggregate SELECT and folds the rows into a map keyed by the
  # source record's `pkey` lookup key. Returns `%{}` when the query fails.
  defp handle_aggregate_result(
         repo,
         query,
         params,
         opts,
         kind,
         field,
         related,
         fk_attr,
         pkey,
         records,
         default_value,
         key_col
       ) do
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

      _ ->
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
    params = Enum.map(values, &convert_uuid_param(&1, col, uuid_fields))
    {"#{Identifier.quote_name(col)} IN (#{placeholders})", params}
  end

  defp aggregate_field_to_cql(:count, nil, _resource), do: "COUNT(*)"

  defp aggregate_field_to_cql(kind, field, resource),
    do: "#{String.upcase(to_string(kind))}(#{resolve_aggregate_field(field, resource)})"

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

  defp build_set_clauses(attrs, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)
    attr_map = attribute_map(resource)

    {clauses, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {cs, vs} ->
        value = encode_attr_value(k, v, attr_map, uuid_fields)
        {["#{Identifier.quote_name(to_string(k))} = ?" | cs], [value | vs]}
      end)

    {Enum.reverse(clauses), :lists.reverse(values)}
  end

  defp attribute_map(resource) do
    resource
    |> Info.attributes()
    |> Enum.reduce(%{}, fn attr, acc -> Map.put(acc, attr.name, attr) end)
  end

  defp encode_attr_value(k, v, attr_map, uuid_fields) do
    cond do
      uuid_field?(k, v, uuid_fields) ->
        case Types.uuid_string_to_binary(v) do
          {:ok, bin} -> bin
          _ -> v
        end

      attr = Map.get(attr_map, k) ->
        Types.encode_value(v, attr)

      true ->
        v
    end
  end

  defp build_pk_where_clause(changeset, resource) do
    pk = get_primary_key_from_changeset(changeset, resource)
    build_where_from_map(pk, resource)
  end

  defp build_where_clause(filters, resource) when is_list(filters) do
    QueryBuilder.build_where_clause(filters, resource)
  end

  defp build_where_clause(nil, _resource), do: {"", []}
  defp build_where_clause([], _resource), do: {"", []}

  defp build_where_from_map(pk_map, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)

    {clauses, values} =
      Enum.reduce(pk_map, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{Identifier.quote_name(to_string(k))} = ?" | cs],
         [convert_uuid_param(v, k, uuid_fields) | vs]}
      end)

    {Enum.reverse(clauses) |> Enum.join(" AND "), :lists.reverse(values)}
  end

  defp uuid_field?(k, _v, uuid_fields) do
    k in uuid_fields
  end

  # Converts a single parameter to its 16-byte UUID binary form *only* when the
  # column it belongs to is known to be UUID-typed. This replaces the old
  # `convert_uuid_params/2` heuristic that mangled any 36-character string that
  # merely looked like a UUID — including legitimate `:string` business
  # identifiers (order numbers, etc.).
  defp convert_uuid_param(value, column, uuid_fields) do
    Types.convert_uuid_param(value, column, uuid_fields)
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

  defp changeset_to_update_attrs(changeset, _resource) do
    # Ash populates `attributes` for directly-built changesets (e.g. from
    # `DataLayer.update_query` tests) but routes atomic/bulk updates through
    # `changeset.changes`. Merge both so the SET clause is built regardless of
    # which path produced the changeset. Plain maps (no `:changes` key) are
    # returned as-is.
    attributes = Map.get(changeset, :attributes, %{})
    changes = Map.get(changeset, :changes, %{})
    Map.merge(attributes, changes)
  end

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

    Types.format_uuid_string(a, b, c, d, e)
  end

  defp autogenerate_attribute?(attr) do
    Map.get(attr, :autogenerate?) == true or is_function(Map.get(attr, :default))
  end

  defp get_primary_key_from_changeset(changeset, resource) do
    source = changeset.data

    Enum.reduce(Info.attributes(resource), %{}, fn attr, acc ->
      if attr.primary_key? do
        case Map.get(source, attr.name) do
          nil -> acc
          val -> Map.put(acc, attr.name, val)
        end
      else
        acc
      end
    end)
  end

  defp attrs_to_row(attrs, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)
    attr_map = attribute_map(resource)

    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), encode_attr_value(k, v, attr_map, uuid_fields))
    end)
  end

  # Builds a consistent (fields, rows) pair for bulk insert. Fields are emitted
  # in the resource's attribute declaration order; each row is a value list
  # aligned to that field order, encoded in a JSON-friendly form suitable for
  # the `JSONCompactEachRow` insert format (UUIDs as strings, maps/arrays as
  # native JSON values).
  defp build_insert_rows(rows, resource) do
    field_atoms =
      resource
      |> Info.attributes()
      |> Enum.map(& &1.name)

    fields =
      resource
      |> Info.attributes()
      |> Enum.map(&Identifier.quote_name(&1.name))

    encoded_rows =
      Enum.map(rows, fn row ->
        Enum.map(field_atoms, fn name ->
          case Map.fetch(row, to_string(name)) do
            {:ok, v} -> encode_bulk_value(v, name, resource)
            :error -> nil
          end
        end)
      end)

    {fields, encoded_rows}
  end

  # Encoding for the JSON bulk insert path. Unlike the parameterized single
  # insert, ClickHouse's JSONCompactEachRow expects native JSON values, so we
  # keep UUIDs as their canonical string form and leave maps/arrays as Elixir
  # maps/lists (Jason serializes them directly).
  #
  # Decimal structs are not natively understood by Jason, so we render them as a
  # numeric string. ClickHouse parses the JSON number on insert, so the value is
  # stored with full precision. If your JSON encoder has a native Decimal
  # implementation you may remove this branch.
  defp encode_bulk_value(%DateTime{} = value, _name, _resource) do
    # ClickHouse's JSONCompactEachRow expects DateTime values as a unix integer
    # (seconds), not a quoted string. DateTime64(N) interprets the integer as
    # whole seconds with zero fractional precision.
    DateTime.to_unix(value, :second)
  end

  defp encode_bulk_value(%NaiveDateTime{} = value, _name, _resource) do
    value
    |> DateTime.from_naive("Etc/UTC")
    |> case do
      {:ok, dt} -> DateTime.to_unix(dt, :second)
      _ -> value
    end
  end

  defp encode_bulk_value(%Date{} = value, _name, _resource) do
    Date.to_erl(value) |> :calendar.date_to_gregorian_days()
  end

  defp encode_bulk_value(%Time{} = value, _name, _resource) do
    Time.to_erl(value) |> (fn {h, m, s} -> h * 3600 + m * 60 + s end).()
  end

  defp encode_bulk_value(%Decimal{} = value, _name, _resource) do
    Decimal.to_string(value, :normal)
  end

  defp encode_bulk_value(value, name, resource) do
    uuid_fields = Types.uuid_attribute_names(resource)

    cond do
      name in uuid_fields and is_binary(value) and byte_size(value) == 16 ->
        case Types.uuid_binary_to_string(value) do
          {:ok, str} -> str
          _ -> value
        end

      name in uuid_fields and is_binary(value) and byte_size(value) == 36 ->
        value

      is_map(value) ->
        value

      is_list(value) ->
        value

      true ->
        value
    end
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

  defp to_ash_record(row, resource) when is_list(row) do
    to_ash_record(row, resource, [])
  end

  defp to_ash_record(row, resource, columns)
       when is_list(row) and is_list(columns) and columns != [] do
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

    record_map =
      row
      |> Enum.zip(attr_names)
      |> Enum.reduce(%{}, fn {v, k}, acc -> Map.put(acc, to_string(k), v) end)

    to_ash_record(record_map, resource)
  end

  defp to_ash_record(row, resource, _columns) when is_map(row) do
    uuid_fields = Types.uuid_attribute_names(resource)
    atom_fields = Types.atom_attribute_names(resource)

    attrs =
      resource
      |> Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        value = Map.get(row, attr.name)
        value = if is_nil(value), do: Map.get(row, to_string(attr.name)), else: value

        decoded =
          cond do
            attr.name in uuid_fields and is_binary(value) and byte_size(value) == 16 ->
              case Types.uuid_binary_to_string(value) do
                {:ok, str} -> str
                _ -> value
              end

            attr.name in atom_fields and is_binary(value) ->
              to_existing_atom(value)

            true ->
              Types.decode_value(value, attr)
          end

        Map.put(acc, attr.name, decoded)
      end)

    struct(resource, attrs)
  end

  # ============================================================================
  # Options / error handling
  # ============================================================================

  defp build_opts(resource), do: build_opts(resource, nil)

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

  defp build_query_opts(_resource) do
    []
  end

  # ClickHouse's async_insert / wait_for_async_insert settings (recommended for
  # high-throughput ingestion) as repo/DSL-level options, defaulting to
  # synchronous inserts for predictable return semantics.
  defp build_insert_opts(resource, opts) do
    resource_opts = Dsl.insert_opts(resource)
    merged = Keyword.merge(resource_opts, opts)

    []
    |> maybe_put(:async_insert, Keyword.get(merged, :async_insert))
    |> maybe_put(:wait_for_async_insert, Keyword.get(merged, :wait_for_async_insert))
  end

  defp to_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_bulk_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_bulk_options(opts) when is_list(opts), do: opts

  defp handle_result({:ok, _} = ok), do: ok
  defp handle_result(:ok), do: :ok

  defp handle_result({:error, %mod{} = error})
       when mod in [
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
