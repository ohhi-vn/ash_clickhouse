defmodule ClickHouse.Result do
  @moduledoc """
  The results of a ClickHouse query.
  """

  @derive {Inspect, only: [:rows, :columns]}
  @enforce_keys [:raw, :meta, :compressed]
  defstruct [:raw, :format, :columns, :meta, :compressed, :rows]

  @typedoc """
  The name of the column.
  """
  @type column_name :: binary()

  @typedoc """
  The names and data types of columns.
  """
  @type columns :: [{column_name(), ClickHouse.data_type()}, ...] | nil

  @typedoc """
  The rows returned from ClickHouse.
  """
  @type rows :: [] | [list(), ...] | nil

  @typedoc """
  The result of a ClickHouse query.
  """
  @type t :: %__MODULE__{
          raw: binary(),
          format: ClickHouse.Format.t(),
          columns: columns(),
          rows: rows(),
          compressed: boolean(),
          meta: map()
        }

  ################################
  # Public API
  ################################

  @spec new(ClickHouse.Client.t(), binary(), binary(), map(), boolean()) :: ClickHouse.Result.t()
  def new(client, raw, format, meta, compressed) do
    %__MODULE__{
      raw: raw,
      format: Map.get(client.formats, format),
      meta: meta,
      compressed: compressed
    }
  end

  @spec decode(ClickHouse.Result.t()) :: ClickHouse.Result.t()
  def decode(%{compressed: true} = result), do: result
  def decode(%{format: nil} = result), do: result

  def decode(result) do
    {columns, rows} = result.format.decode(result.raw)
    %{result | columns: columns, rows: rows}
  end
end
