defmodule ClickHouse do
  @moduledoc """
  A ClickHouse client.

  This currently represents an early work in progress.
  """

  use Supervisor

  alias ClickHouse.{Client, Query, Result, Stream, Telemetry}

  @start_opts KeywordValidator.schema!(
                name: [
                  is: :atom,
                  required: true,
                  default: :default,
                  doc: "The name of the client."
                ],
                interface: [
                  is: :mod,
                  required: true,
                  default: ClickHouse.Interface.HTTP,
                  doc: "The network interface to use for queries."
                ],
                formats: [
                  is: {:list, :mod},
                  required: true,
                  default: [
                    ClickHouse.Format.JSONCompactEachRow,
                    ClickHouse.Format.RowBinary,
                    ClickHouse.Format.TSV,
                    ClickHouse.Format.TSVWithNames,
                    ClickHouse.Format.TSVWithNamesAndTypes,
                    ClickHouse.Format.Values
                  ],
                  doc: "A list of formats available for encoding/decoding."
                ]
              )

  ################################
  # Types
  ################################

  @typedoc """
  A ClickHouse client.
  """
  @type client :: atom() | ClickHouse.Client.t()

  @typedoc """
  A query statement.
  """
  @type statement :: binary() | struct()

  @typedoc """
  Parameters used with queries.

  Optional data types can be provided in a tuple format.
  """
  @type params :: list() | {data_types(), list()}

  @typedoc """
  A list of data types.
  """
  @type data_types :: list(data_type())

  @typedoc """
  The data types available.
  """
  @type data_type ::
          :i64
          | :i32
          | :i16
          | :i8
          | :u64
          | :u32
          | :u16
          | :u8
          | :f64
          | :f32
          | :string
          | :uuid
          | :date
          | :datetime
          | {:datetime64, integer()}
          | {:fixed_string, integer()}
          | {:enum8, %{(String.t() | atom()) => integer()}}
          | {:enum16, %{(String.t() | atom()) => integer()}}
          | {:array, data_type()}
          | {:low_cardinality, data_type()}
          | {:nullable, data_type()}
          | {:tuple, [data_type()]}
          | {{:simple_aggregate_function, atom()}, data_type()}

  @typedoc """
  Options used for `child_spec/1` and `start_link/1`
  """
  @type start_option ::
          {:name, atom()}
          | {:interface, ClickHouse.Interface.t()}
          | {:formats, [ClickHouse.Format.t()]}

  @typedoc """
  Various representations of ClickHouse-related errors.
  """
  @type error ::
          ClickHouse.ConnectionError.t()
          | ClickHouse.CoordinationError.t()
          | ClickHouse.DatabaseError.t()
          | ClickHouse.ParsingError.t()
          | ClickHouse.QueryError.t()
          | ClickHouse.StreamError.t()
          | ClickHouse.SystemError.t()

  ################################
  # Public API
  ################################

  @doc """
  Starts a ClickHouse client.

  ## Options

  #{KeywordValidator.docs(@start_opts)}

  ## Extra Options

  Any additional options passed will be given to the client interface.
  """
  @spec start_link([start_option()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts_keys = Keyword.keys(@start_opts.schema)
    {opts, extra_opts} = Keyword.split(opts, opts_keys)
    opts = KeywordValidator.validate!(opts, @start_opts)
    Supervisor.start_link(__MODULE__, {opts, extra_opts})
  end

  @doc """
  Prepares and executes a query using a ClickHouse client.
  """
  @spec query(client(), statement(), params(), keyword()) ::
          {:ok, ClickHouse.Result.t()} | {:error, error()}
  def query(client, statement, params \\ [], opts \\ [])

  def query(%Client{} = client, statement, params, opts) do
    query = prepare(client, statement, params)
    execute(client, query, opts)
  end

  def query(client, statement, params, opts) when is_atom(client) do
    client = fetch_client!(client)
    query(client, statement, params, opts)
  end

  @doc """
  Prepares a query for a ClickHouse client.
  """
  @spec prepare(client(), statement(), params()) :: ClickHouse.Query.t()
  def prepare(client, statement, params \\ [])

  def prepare(%Client{} = client, statement, params) do
    Telemetry.span(:prepare, %{client: client.name}, fn ->
      result = Query.prepare(client, statement, params)
      {result, %{client: client.name}}
    end)
  end

  def prepare(client, statement, params) when is_atom(client) do
    client = fetch_client!(client)
    prepare(client, statement, params)
  end

  @doc """
  Executes a query using a ClickHouse client.
  """
  @spec execute(client(), ClickHouse.Query.t(), opts :: keyword()) ::
          {:ok, ClickHouse.Result.t()} | {:error, error()}
  def execute(client, query, opts \\ [])

  def execute(%Client{} = client, query, opts) do
    Telemetry.span(:execute, %{client: client.name}, fn ->
      result =
        case client.interface.execute(client, query, opts) do
          {:ok, result} ->
            result = Result.decode(result)
            {:ok, result}

          {:error, error} ->
            Telemetry.error(:execute, error, %{client: client.name})
            {:error, error}
        end

      {result, %{client: client.name}}
    end)
  end

  def execute(client, query, opts) when is_atom(client) do
    client = fetch_client!(client)
    execute(client, query, opts)
  end

  @doc """
  Creates a new query stream using a ClickHouse client.
  """
  @spec stream!(client(), statement(), params(), opts :: keyword()) :: ClickHouse.Stream.t()
  def stream!(client, query, params \\ [], opts \\ [])

  def stream!(%Client{} = client, statement, params, opts) do
    query = prepare(client, statement, params)
    Stream.new(client, query, opts)
  end

  def stream!(client, statement, params, opts) when is_atom(client) do
    client = fetch_client!(client)
    stream!(client, statement, params, opts)
  end

  ################################
  # Supervisor Callbacks
  ################################

  @impl Supervisor
  def init({opts, extra_opts}) do
    client = init_client(opts)

    children = [
      interface(opts, extra_opts)
    ]

    Telemetry.span(:init, %{client: client.name}, fn ->
      result = Supervisor.init(children, strategy: :one_for_one)
      {result, %{client: client.name}}
    end)
  end

  ################################
  # Private API
  ################################

  defp init_client(opts) do
    client = Client.new(opts)
    :ok = :persistent_term.put({__MODULE__, client.name}, client)
    client
  end

  defp fetch_client!(name) do
    :persistent_term.get({__MODULE__, name})
  rescue
    ArgumentError ->
      # credo:disable-for-next-line
      raise ArgumentError, """
      No ClickHouse client #{inspect(name)} available.
      """
  end

  defp interface(opts, extra_opts) do
    client = Keyword.fetch!(opts, :name)
    interface = Keyword.fetch!(opts, :interface)
    interface_opts = Keyword.put(extra_opts, :name, client)

    {interface, interface_opts}
  end
end
