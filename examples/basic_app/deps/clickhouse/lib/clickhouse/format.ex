defmodule ClickHouse.Format do
  @moduledoc """
  A behaviour to implement encoding and decoding of ClickHouse queries and results.
  """

  @typedoc "Input and output formats from ClickHouse."
  @type t :: module()

  @typedoc "A ClickHouse format name."
  @type name :: binary()

  @doc """
  A callback to return the names used for the format.
  """
  @callback names :: [name()]

  @doc """
  A callback to build iodata for the given types and rows.
  """
  @callback encode(ClickHouse.data_types(), rows :: list()) :: iodata()

  @doc """
  A callback to decode columns and rows with the format.
  """
  @callback decode(raw :: iodata()) :: {ClickHouse.Result.columns(), ClickHouse.Result.rows()}
end
