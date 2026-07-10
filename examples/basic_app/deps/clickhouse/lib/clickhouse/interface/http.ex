defmodule ClickHouse.Interface.HTTP do
  @moduledoc """
  An interface to interact with a ClickHouse server via HTTP.
  """

  @behaviour ClickHouse.Interface

  use GenServer

  require Logger

  alias ClickHouse.Interface.HTTP.Client
  alias ClickHouse.Result

  @opts_schema KeywordValidator.schema!(
                 name: [is: :atom, required: true, default: :default],
                 urls: [is: {:list, :binary}, required: true, default: ["http://localhost:8123"]],
                 ping_retry: [is: :integer, required: true, default: 3_000],
                 pool_timeout: [is: :integer, required: true, default: 150_000],
                 pool_max_connections: [is: :integer, required: true, default: 50]
               )

  @ping_statement "SELECT 1"

  ################################
  # ClickHouse.Interface Callbacks
  ################################

  @doc """
  Starts the HTTP network interface.
  """
  @impl ClickHouse.Interface
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = KeywordValidator.validate!(opts, @opts_schema)
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Executes a query via HTTP.
  """
  @impl ClickHouse.Interface
  @spec execute(ClickHouse.Client.t(), ClickHouse.Query.t(), keyword()) ::
          {:ok, ClickHouse.Result.t()} | {:error, ClickHouse.error()}
  def execute(client, query, opts \\ []) do
    {pool, urls} = fetch_config!(client)
    opts = Keyword.put(opts, :stream, false)

    with {:ok, result} <- Client.request(pool, urls, query.statement, opts) do
      result = build_result(client, result)
      {:ok, result}
    end
  end

  @doc """
  Starts a query result stream via HTTP.
  """
  @impl ClickHouse.Interface
  @spec stream_start(ClickHouse.Stream.t()) ::
          {:ok, ClickHouse.Stream.t()} | {:error, ClickHouse.error()}
  def stream_start(stream) do
    {pool, urls} = fetch_config!(stream.client)
    opts = Keyword.put(stream.opts, :stream, true)

    with {:ok, {ref, opts}} <- Client.request(pool, urls, stream.query.statement, opts) do
      stream = %{stream | id: ref, opts: opts}
      {:ok, stream}
    end
  end

  @doc """
  Streams the next results of a query via HTTP.
  """
  @impl ClickHouse.Interface
  @spec stream_next(ClickHouse.Stream.t()) ::
          {:cont, ClickHouse.Stream.t()}
          | {:cont, ClickHouse.Stream.t(), iodata()}
          | {:halt, ClickHouse.Stream.t()}
          | {:error, ClickHouse.error()}
  def stream_next(stream) do
    case Client.stream_next(stream.id, stream.opts) do
      :begin ->
        {:cont, stream}

      {:headers, _} ->
        {:cont, stream}

      {:chunk, data} ->
        {:cont, stream, data}

      :halt ->
        {:halt, stream}

      {:error, _} = error ->
        error
    end
  end

  @impl ClickHouse.Interface
  def stream_into_start(stream) do
    {pool, urls} = fetch_config!(stream.client)
    opts = stream.opts ++ [query: to_string(stream.query.statement)]

    with {:ok, {ref, opts}} <- Client.request(pool, urls, :stream, opts) do
      stream = %{stream | id: ref, opts: opts}
      {:ok, stream}
    end
  end

  @impl ClickHouse.Interface
  def stream_into_next(stream, command) do
    case command do
      {:cont, body} ->
        :ok = Client.send_body(stream.id, body)
        {:ok, stream}

      :halt ->
        Client.close(stream.id)
        {:ok, stream}

      :done ->
        with {:ok, result} <- Client.start_response(stream.id, stream.opts) do
          result = build_result(stream.client, result)
          {:ok, result}
        end
    end
  end

  ################################
  # GenServer Callbacks
  ################################

  @impl GenServer
  def init(opts) do
    state = init_state(opts)
    init_config(state)
    init_pool(state)
    {:ok, state, {:continue, :ping}}
  end

  @impl GenServer
  def handle_continue(:ping, state) do
    ping(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:retry_ping, state) do
    {:noreply, state, {:continue, :ping}}
  end

  ################################
  # Private API
  ################################

  defp init_state(opts) do
    name = Keyword.get(opts, :name)

    %{
      name: name,
      table_name: table_name(name),
      pool_name: pool_name(name),
      pool_opts: [
        timeout: Keyword.get(opts, :pool_timeout),
        max_connections: Keyword.get(opts, :pool_max_connections)
      ],
      urls: Keyword.get(opts, :urls),
      ping_retry: Keyword.get(opts, :ping_retry)
    }
  end

  defp init_config(state) do
    config = {state.pool_name, state.urls}
    :ets.new(state.table_name, [:named_table, read_concurrency: true])
    :ets.insert(state.table_name, {:config, config})
  end

  defp fetch_config!(client) do
    case :ets.lookup(table_name(client.name), :config) do
      [{:config, config}] -> config
      _ -> raise ArgumentError, "No client interface available"
    end
  end

  defp init_pool(state) do
    :hackney_pool.start_pool(state.pool_name, state.pool_opts)
  end

  defp table_name(name) do
    :"#{__MODULE__}.#{name}"
  end

  defp pool_name(name) do
    :"#{__MODULE__}.#{name}.http_pool"
  end

  defp ping(state) do
    case Client.request(state.pool_name, state.urls, @ping_statement, []) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("[ClickHouse.Interface.HTTP] Ping error: #{inspect(error)}")
        Process.send_after(self(), :retry_ping, state.ping_retry)
        :error
    end
  end

  defp build_result(client, {body, format, meta, compressed}) do
    Result.new(client, body, format, meta, compressed)
  end
end
