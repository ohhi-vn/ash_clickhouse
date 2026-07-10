defmodule ClickHouse.Format.Values do
  @moduledoc """
  An implementation of the ClickHouse `Values` format.
  """

  @behaviour ClickHouse.Format

  import ClickHouse.Utils, only: [intersperse_map: 3, escape: 1]

  ################################
  # ClickHouse.Format Callbacks
  ################################

  @impl ClickHouse.Format
  @spec names() :: [binary()]
  def names, do: ["Values"]

  @impl ClickHouse.Format
  @spec decode(raw :: iodata()) :: no_return()
  def decode(_raw) do
    raise ClickHouse.QueryError, """
    Values decode not implemented.
    """
  end

  @impl ClickHouse.Format
  @spec encode(ClickHouse.data_types(), rows :: list()) :: iodata()
  def encode(_types, rows) do
    intersperse_map(rows, ",", fn row ->
      ["(", intersperse_map(row, ",", &encode_value/1), ")"]
    end)
  end

  ################################
  # Private API
  ################################

  defp encode_value(value) when is_binary(value) do
    ["'", escape(value), "'"]
  end

  defp encode_value(false), do: "0"
  defp encode_value(true), do: "1"
  defp encode_value(nil), do: "NULL"

  defp encode_value(value) when is_atom(value) do
    value = to_string(value)
    ["'", escape(value), "'"]
  end

  defp encode_value(value) when is_list(value) do
    ["[", intersperse_map(value, ",", &encode_value/1), "]"]
  end

  defp encode_value(value) when is_float(value), do: to_string(value)
  defp encode_value(value) when is_integer(value), do: to_string(value)

  defp encode_value(tuple) when is_tuple(tuple) do
    list = Tuple.to_list(tuple)
    ["tuple(", intersperse_map(list, ",", &encode_value/1), ")"]
  end

  defp encode_value(%Date{} = value), do: ["'", to_string(value), "'"]

  defp encode_value(%DateTime{} = value) do
    value =
      value
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace("Z", "")

    ["'", value, "'"]
  end
end
