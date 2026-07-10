if Code.ensure_loaded?(NimbleCSV) do
  defmodule ClickHouse.Format.TSV do
    @moduledoc """
    An implementation of the ClickHouse `TSV` format.
    """

    @behaviour ClickHouse.Format

    import ClickHouse.Utils, only: [escape: 1]

    alias ClickHouse.DataType

    @parser __MODULE__.Parser

    NimbleCSV.define(@parser, moduledoc: false, separator: "\t", escape: "\"'")

    ################################
    # ClickHouse.Format Callbacks
    ################################

    @impl ClickHouse.Format
    @spec names() :: [binary()]
    def names, do: ["TabSeparated", "TSV"]

    @impl ClickHouse.Format
    @spec decode(raw :: iodata()) :: {ClickHouse.Result.columns(), ClickHouse.Result.rows()}
    def decode(raw) do
      rows = @parser.parse_string(raw, skip_headers: false)
      {nil, rows}
    end

    @impl ClickHouse.Format
    @spec encode(ClickHouse.data_types(), rows :: list()) :: iodata()
    def encode(_types, rows) do
      rows
      |> Enum.map(&encode_row/1)
      |> @parser.dump_to_iodata()
    end

    ################################
    # Private API
    ################################

    defp encode_row(row), do: Enum.map(row, &encode_value/1)

    defp encode_value(data) when is_binary(data), do: escape(data)
    defp encode_value(data) when is_list(data), do: DataType.encode(data)
    defp encode_value(nil), do: "\\N"
    defp encode_value(true), do: 1
    defp encode_value(false), do: 0
    defp encode_value(data) when is_atom(data), do: data |> to_string() |> escape()
    defp encode_value(data) when is_float(data), do: to_string(data)
    defp encode_value(data) when is_integer(data), do: to_string(data)
    defp encode_value(data) when is_bitstring(data), do: data |> to_string() |> escape()
    defp encode_value(%Date{} = data), do: to_string(data)

    defp encode_value(%DateTime{} = data) do
      data
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace("Z", "")
    end
  end
end
