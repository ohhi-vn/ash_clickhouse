if Code.ensure_loaded?(Jason) do
  defmodule ClickHouse.Format.JSONCompactEachRow do
    @moduledoc """
    An implementation of the ClickHouse `JSONCompactEachRow` format.
    """

    @behaviour ClickHouse.Format

    import ClickHouse.Utils, only: [intersperse_map: 3]

    @newline ["\n"]

    ################################
    # ClickHouse.Format Callbacks
    ################################

    @impl ClickHouse.Format
    @spec names() :: [binary()]
    def names, do: ["JSONCompactEachRow"]

    @impl ClickHouse.Format
    @spec decode(raw :: iodata()) :: {ClickHouse.Result.columns(), ClickHouse.Result.rows()}
    def decode(raw) do
      rows = do_decode(raw, [])
      {nil, rows}
    end

    @impl ClickHouse.Format
    @spec encode(ClickHouse.data_types(), rows :: list()) :: iodata()
    def encode(_types, rows) do
      intersperse_map(rows, "\n", &Jason.encode!/1)
    end

    ################################
    # Private API
    ################################

    defp do_decode(raw, rows) do
      case :binary.split(raw, @newline) do
        [row, rest] ->
          row = Jason.decode!(row)
          do_decode(rest, [row | rows])

        [""] ->
          Enum.reverse(rows)
      end
    end
  end
end
