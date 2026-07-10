defmodule AshClickhouse.Connection do
  @moduledoc """
  Process wrapper around the `clickhouse` client connection.

  A connection is a named process that holds the configuration for a
  ClickHouse database. Queries are dispatched through this module so that the
  rest of the data layer does not need to know the details of the underlying
  client.

  ## Options

  - `:name` — register the connection under this name (atom)
  - `:url` — the ClickHouse HTTP URL, e.g. `"http://localhost:8123"`
  - `:username` / `:password` — credentials
  - `:database` — the default database
  - `:otp_app` — application to read config from (used by `AshClickhouse.Repo`)

  The `clickhouse` client is started as a supervised GenServer. We keep a thin
  wrapper so that the data layer can resolve a connection by name and run
  queries with consistent error handling.
  """

  require Logger

  @default_format "JSONCompactEachRow"
  @default_pool_timeout 30_000
  @default_ping_retry 30_000

  defstruct [:conn, :database, :name, :pid]

  @type t :: %AshClickhouse.Connection{
          conn: pid() | atom(),
          database: String.t() | nil,
          name: atom() | nil,
          pid: pid() | nil
        }

  @doc """
  Starts a ClickHouse connection as part of a supervision tree.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    conn_opts = clickhouse_opts(opts)

    case ClickHouse.start_link(conn_opts) do
      {:ok, pid} ->
        conn = %AshClickhouse.Connection{
          conn: name || pid,
          database: Keyword.get(opts, :database),
          name: name,
          pid: pid
        }

        if name do
          :persistent_term.put({__MODULE__, name}, conn)
        end

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the child spec for a connection (for supervision trees).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Returns the connection struct registered under `name`, if any.
  """
  @spec get_conn(atom()) :: t() | nil
  def get_conn(name \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> nil
      %__MODULE__{} = conn -> conn
    end
  end

  @doc """
  Runs a SQL query against ClickHouse.

  Returns `{:ok, %ClickHouse.Result{}}` or `{:error, %ClickHouse.Error{}}`.
  """
  @spec query(t() | atom(), String.t(), list(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def query(conn_or_name, sql, params \\ [], opts \\ []) do
    {conn, opts} = resolve_conn(conn_or_name, opts)
    ClickHouse.query(conn, sql, params, with_default_format(opts))
  rescue
    e -> {:error, e}
  end

  @doc """
  Runs a SQL query, raising on error.
  """
  @spec query!(t() | atom(), String.t(), list(), keyword()) :: term()
  def query!(conn_or_name, sql, params \\ [], opts \\ []) do
    {conn, opts} = resolve_conn(conn_or_name, opts)
    {:ok, result} = ClickHouse.query(conn, sql, params, with_default_format(opts))
    result
  end

  @doc """
  Inserts rows into a table using the client's bulk insert helper.

  `statement` must be a fully-formed `INSERT INTO <table> (...) FORMAT
  JSONCompactEachRow` query; `rows` is a list of value-lists (one per row) in the
  same column order as the statement. Options are forwarded to the underlying
  client (e.g. `async_insert`/`wait_for_async_insert`).
  """
  @spec insert_rows(t() | atom(), String.t(), String.t(), [list()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def insert_rows(conn_or_name, _table, statement, rows, opts \\ []) when is_list(rows) do
    {conn, opts} = resolve_conn(conn_or_name, opts)
    ClickHouse.query(conn, statement, rows, with_default_format(opts))
  rescue
    e -> {:error, e}
  end

  @doc """
  Returns the configured database for a connection (by name, struct, or pid),
  or `nil` if unknown. Used to thread the database into per-query opts without
  baking it into the connection URL.
  """
  @spec database_for(t() | atom() | pid()) :: String.t() | nil
  def database_for(%__MODULE__{database: database}), do: database

  def database_for(name) when is_atom(name) do
    case get_conn(name) do
      %__MODULE__{database: database} -> database
      _ -> nil
    end
  end

  def database_for(_), do: nil

  @doc """
  Stops the connection.

  Terminates the underlying ClickHouse client process (registered under
  `name`) and removes the cached connection struct from `:persistent_term`.
  Returns `:ok` if there was no connection to stop, or `{:error, reason}` if
  the client process could not be stopped.
  """
  @spec stop(t() | atom()) :: :ok | {:error, term()}
  def stop(name) when is_atom(name) do
    case get_conn(name) do
      nil ->
        :ok

      %__MODULE__{pid: pid, conn: conn} ->
        :persistent_term.erase({__MODULE__, name})
        do_stop_client(pid || conn)
    end
  end

  def stop(%__MODULE__{conn: conn, name: name, pid: pid}) when not is_nil(name) do
    :persistent_term.erase({__MODULE__, name})
    do_stop_client(pid || conn)
  end

  def stop(%__MODULE__{conn: conn, pid: pid}) do
    do_stop_client(pid || conn)
  end

  def stop(_), do: :ok

  defp do_stop_client(conn) when is_pid(conn) do
    case Supervisor.stop(conn) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> :ok
  end

  # The ClickHouse client is started as an unnamed Supervisor and referenced
  # only via `:persistent_term`/the pid we stored, so we cannot resolve an atom
  # name to a pid through the public API. Callers always pass the stored pid,
  # but if we somehow receive only an atom we treat it as already-stopped.
  defp do_stop_client(_), do: :ok

  # --- internals -----------------------------------------------------------

  # Resolves the client connection and the database to target. The database is
  # threaded through the per-query `opts` (as `:database`) rather than baked
  # into the connection URL: the `clickhouse` client appends every opt in
  # `build_url/2` with its own `?` separator, so a URL that already contains
  # `?database=...` would produce a malformed double-`?` URL
  # (`...?database=x?default_format=y`) that ClickHouse rejects as an unknown
  # setting. Passing `database` via opts lets the client emit a clean
  # `?database=...&default_format=...`.
  defp resolve_conn(%__MODULE__{conn: conn, database: database}, opts) do
    {conn, with_database(opts, database)}
  end

  defp resolve_conn(name, opts) when is_atom(name) do
    case get_conn(name) do
      %__MODULE__{conn: conn, database: database} -> {conn, with_database(opts, database)}
      _ -> {name, opts}
    end
  end

  defp resolve_conn(conn, opts), do: {conn, opts}

  defp with_database(opts, nil), do: opts

  defp with_database(opts, database) do
    if Keyword.has_key?(opts, :database) do
      opts
    else
      [{:database, database} | opts]
    end
  end

  # The `clickhouse` client appends `default_format` to the URL query string via
  # its own `?` separator, so we pass it as a per-query option rather than
  # baking it into the connection URL. This keeps the generated URL well-formed
  # (`?database=...&default_format=...`). Exposed publicly so the data layer's
  # streaming path can apply the same format without going through `query/4`.
  @doc false
  @spec with_default_format(keyword()) :: keyword()
  def with_default_format(opts) do
    if Keyword.has_key?(opts, :default_format) do
      opts
    else
      [{:default_format, @default_format} | opts]
    end
  end

  defp clickhouse_opts(opts) do
    url = Keyword.get(opts, :url, "http://localhost:8123")
    name = Keyword.get(opts, :name, __MODULE__)
    pool_timeout = Keyword.get(opts, :pool_timeout, @default_pool_timeout)
    ping_retry = Keyword.get(opts, :ping_retry, @default_ping_retry)
    pool_size = Keyword.get(opts, :pool_size, 10)

    # NOTE: the `database` is intentionally NOT baked into the URL here. It is
    # threaded per-query via `resolve_conn/2` (as the `:database` opt) so the
    # `clickhouse` client can append it with a single, well-formed `?` separator
    # alongside `default_format`. Baking it into the URL would produce a doubled
    # `?` and a malformed request that ClickHouse rejects.
    [
      name: name,
      interface: ClickHouse.Interface.HTTP,
      urls: [url],
      pool_timeout: pool_timeout,
      ping_retry: ping_retry,
      pool_max_connections: pool_size
    ]
  end
end
