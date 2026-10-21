defmodule AshClickhouse.FakeRepo do
  @moduledoc """
  A query-counting fake repo for the ClickHouse data layer's action-level tests.

  Every statement the data layer issues is recorded, so a test can assert on
  the *number* of round-trips as well as on the SQL that was sent. That is the
  only way to catch the "the same aggregate is issued twice" class of defect,
  which is invisible in the values the query returns.

  Responses are programmable: queue the rows each statement should return, or
  set a default response used once the queue is empty.
  """

  use Agent

  @default_rows [["id-1", "alice", "alice@example.com", 30]]

  @doc """
  Starts the fake repo, registering it under this module's name.

  Starting an already-running repo reuses the running agent, so several test
  files can share it.
  """
  @spec start() :: {:ok, pid()}
  def start do
    case Process.whereis(__MODULE__) do
      nil -> Agent.start(fn -> initial_state() end, name: __MODULE__)
      pid -> {:ok, pid}
    end
  end

  @doc "Resets the recorded calls and the queued responses."
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _state -> initial_state() end)
  end

  @doc "The statements issued so far, oldest first."
  @spec calls() :: [{atom(), String.t(), list()}]
  def calls do
    Agent.get(__MODULE__, & &1.calls)
  end

  @doc "The number of statements issued so far."
  @spec query_count() :: non_neg_integer()
  def query_count, do: length(calls())

  @doc "The options each statement was issued with, oldest first."
  @spec query_opts() :: [keyword()]
  def query_opts do
    Agent.get(__MODULE__, &Enum.reverse(&1.query_opts))
  end

  @doc "The SQL of each statement issued so far, oldest first."
  @spec queries() :: [String.t()]
  def queries, do: Enum.map(calls(), fn {_kind, sql, _params} -> sql end)

  @doc """
  Queues the rows the next statement returns.

  `columns` is optional; when omitted the rows are decoded positionally
  against the resource's attribute order.
  """
  @spec queue_response(list(), [String.t()] | nil) :: :ok
  def queue_response(rows, columns \\ nil) do
    Agent.update(__MODULE__, fn state ->
      %{state | responses: state.responses ++ [{rows, columns}]}
    end)
  end

  @doc "Sets the rows returned once the queue is empty."
  @spec default_response(list(), [String.t()] | nil) :: :ok
  def default_response(rows, columns \\ nil) do
    Agent.update(__MODULE__, fn state -> %{state | default: {rows, columns}} end)
  end

  @doc "Makes the next statement fail with `reason`."
  @spec fail_next(term()) :: :ok
  def fail_next(reason) do
    Agent.update(__MODULE__, fn state ->
      %{state | responses: state.responses ++ [{:error, reason}]}
    end)
  end

  # --- repo callbacks --------------------------------------------------------

  @doc false
  def query(sql, params, opts \\ []) do
    record({:query, sql, params})
    record_opts(opts)

    case next_response() do
      {:error, reason} ->
        {:error, reason}

      {rows, columns} ->
        {:ok,
         %ClickHouse.Result{
           raw: "",
           meta: %{},
           compressed: false,
           rows: rows,
           columns: columns
         }}
    end
  end

  @doc false
  def query!(sql, params, _opts \\ []) do
    record({:query!, sql, params})

    %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}
  end

  @doc false
  def insert_rows(statement, rows, _opts \\ []) do
    record({:insert_rows, statement, length(rows)})
    {:ok, :ok}
  end

  @doc false
  def database, do: nil

  # --- internals -------------------------------------------------------------

  defp initial_state do
    %{calls: [], query_opts: [], responses: [], default: {@default_rows, nil}}
  end

  defp record(call) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.update(pid, &%{&1 | calls: &1.calls ++ [call]})
    end
  end

  defp record_opts(opts) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.update(pid, &%{&1 | query_opts: &1.query_opts ++ [opts]})
    end
  end

  defp next_response do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.responses do
        [] ->
          {state.default, state}

        [{:error, reason} | rest] ->
          {{:error, reason}, %{state | responses: rest}}

        [{rows, columns} | rest] ->
          {{rows, columns}, %{state | responses: rest}}
      end
    end)
  end
end
