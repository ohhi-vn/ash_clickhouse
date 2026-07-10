defmodule ClickHouse.Stream do
  @moduledoc """
  Defines a `ClickHouse.Stream` struct returned by `ClickHouse.stream!/4`.
  """

  defstruct [:client, :query, :opts, :id]

  @type t :: %__MODULE__{
          client: ClickHouse.Client.t(),
          query: ClickHouse.Query.t(),
          opts: keyword(),
          id: nil | reference()
        }

  @doc false
  @spec new(ClickHouse.client(), ClickHouse.Query.t(), opts :: keyword()) :: ClickHouse.Stream.t()
  def new(client, query, opts) do
    %__MODULE__{client: client, query: query, opts: opts}
  end
end

defimpl Enumerable, for: ClickHouse.Stream do
  def reduce(stream, acc, fun) do
    stream_start = fn ->
      case stream.client.interface.stream_start(stream) do
        {:ok, stream} ->
          stream

        {:error, error} ->
          raise error
      end
    end

    stream_next = fn stream ->
      case stream.client.interface.stream_next(stream) do
        {:cont, stream} ->
          {[], stream}

        {:cont, stream, data} ->
          {[data], stream}

        {:halt, stream} ->
          {:halt, stream}

        {:error, error} ->
          raise error
      end
    end

    Stream.resource(stream_start, stream_next, & &1).(acc, fun)
  end

  def member?(_, _) do
    {:error, __MODULE__}
  end

  def count(_) do
    {:error, __MODULE__}
  end

  def slice(_) do
    {:error, __MODULE__}
  end
end

defimpl Collectable, for: ClickHouse.Stream do
  def into(stream) do
    stream =
      case stream.client.interface.stream_into_start(stream) do
        {:ok, stream} -> stream
        {:error, error} -> raise error
      end

    collector_fun = fn stream, command ->
      case stream.client.interface.stream_into_next(stream, command) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end
    end

    {stream, collector_fun}
  end
end
