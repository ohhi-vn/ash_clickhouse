defmodule ClickHouse.Interface do
  @moduledoc """
  A behaviour to implement a network interface with a ClickHouse server.
  """

  @typedoc """
  The ClickHouse network interface.
  """
  @type t :: module()

  @doc """
  A callback to start the network interface.
  """
  @callback start_link(keyword()) :: GenServer.on_start()

  @doc """
  A callback to execute a query with the network interface.
  """
  @callback execute(
              client :: ClickHouse.Client.t(),
              query :: ClickHouse.Query.t(),
              opts :: keyword()
            ) ::
              {:ok, ClickHouse.Result.t()} | {:error, ClickHouse.error()}

  @doc """
  A callback to start a query stream with the network interface.
  """
  @callback stream_start(ClickHouse.Stream.t()) ::
              {:ok, ClickHouse.Stream.t()} | {:error, ClickHouse.error()}

  @doc """
  A callback to stream the next chunk with the network interface.
  """
  @callback stream_next(ClickHouse.Stream.t()) ::
              {:cont, ClickHouse.Stream.t()}
              | {:cont, ClickHouse.Stream.t(), iodata()}
              | {:halt, ClickHouse.Stream.t()}
              | {:error, ClickHouse.error()}

  @doc """
  A callback to start streaming a collectable into the network interface.
  """
  @callback stream_into_start(ClickHouse.Stream.t()) ::
              {:ok, ClickHouse.Stream.t()} | {:error, ClickHouse.error()}

  @doc """
  A callback to stream the next chunk into the network interface.
  """
  @callback stream_into_next(ClickHouse.Stream.t(), {:cont, iodata()} | :done | :halt) ::
              {:ok, ClickHouse.Stream.t() | ClickHouse.Result.t()} | {:error, ClickHouse.error()}
end
