if Code.ensure_loaded?(NimbleCSV) do
  defmodule ClickHouse.Format.TSVWithNames do
    @moduledoc """
    An implementation of the ClickHouse `TSVWithNames` format.
    """

    @behaviour ClickHouse.Format

    alias ClickHouse.Format.TSV

    @parser TSV.Parser

    ################################
    # ClickHouse.Format Callbacks
    ################################

    @impl ClickHouse.Format
    @spec names() :: [binary()]
    def names, do: ["TabSeparatedWithNames", "TSVWithNames"]

    @impl ClickHouse.Format
    @spec decode(raw :: iodata()) :: {ClickHouse.Result.columns(), ClickHouse.Result.rows()}
    def decode(raw) do
      [names | rows] = @parser.parse_string(raw, skip_headers: false)
      columns = Enum.map(names, fn name -> {name, nil} end)
      {columns, rows}
    end

    @impl ClickHouse.Format
    @spec encode(ClickHouse.data_types(), rows :: list()) :: iodata()
    def encode(_types, []), do: []

    def encode(_types, [names | rows]) do
      [@parser.dump_to_iodata([names]), TSV.encode([], rows)]
    end

    def encode(_, _) do
      raise ArgumentError, "missing TSV column names"
    end
  end
end
