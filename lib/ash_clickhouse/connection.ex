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

  defstruct [:conn, :database, :name]

  @type t :: %AshClickhouse.Connection{
          conn: pid() | atom(),
          database: String.t() | nil,
          name: atom() | nil
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
          name: name
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
    ClickHouse.query(conn, sql, params, opts)
  rescue
    e -> {:error, e}
  end

  @doc """
  Runs a SQL query, raising on error.
  """
  @spec query!(t() | atom(), String.t(), list(), keyword()) :: term()
  def query!(conn_or_name, sql, params \\ [], opts \\ []) do
    {conn, opts} = resolve_conn(conn_or_name, opts)
    {:ok, result} = ClickHouse.query(conn, sql, params, opts)
    result
  end

  @doc """
  Inserts rows into a table using the client's bulk insert helper.
  """
  @spec insert_rows(t() | atom(), String.t(), [map()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def insert_rows(conn_or_name, table, rows, opts \\ []) when is_list(rows) do
    {conn, opts} = resolve_conn(conn_or_name, opts)
    ClickHouse.insert(conn, table, rows, opts)
  rescue
    e -> {:error, e}
  end

  @doc """
  Stops the connection.
  """
  @spec stop(t() | atom()) :: :ok
  def stop(name) when is_atom(name) do
    case get_conn(name) do
      nil -> :ok
      _ -> :ok
    end
  end

  def stop(%__MODULE__{name: name}) when not is_nil(name) do
    :persistent_term.erase({__MODULE__, name})
    :ok
  end

  def stop(_), do: :ok

  # --- internals -----------------------------------------------------------

  defp resolve_conn(%__MODULE__{conn: conn}, opts), do: {conn, opts}
  defp resolve_conn(name, opts) when is_atom(name), do: {name, opts}
  defp resolve_conn(conn, opts), do: {conn, opts}

  defp clickhouse_opts(opts) do
    url = Keyword.get(opts, :url, "http://localhost:8123")
    database = Keyword.get(opts, :database)
    name = Keyword.get(opts, :name, __MODULE__)
    pool_timeout = Keyword.get(opts, :pool_timeout, @default_pool_timeout)
    ping_retry = Keyword.get(opts, :ping_retry, @default_ping_retry)

    query_params = [default_format: @default_format]
    query_params = if database, do: query_params ++ [database: database], else: query_params
    url = append_query_params(url, query_params)

    [
      name: name,
      interface: ClickHouse.Interface.HTTP,
      urls: [url],
      pool_timeout: pool_timeout,
      ping_retry: ping_retry
    ]
  end

  defp append_query_params(url, []), do: url
  defp append_query_params(url, params) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    "#{url}#{separator}#{URI.encode_query(params)}"
  end
end
