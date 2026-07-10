if Code.ensure_loaded?(NimbleCSV) do
  defmodule ClickHouse.Format.TSVWithNamesAndTypes do
    @moduledoc """
    An implementation of the ClickHouse `TSVWithNamesAndTypes` format.
    """

    @behaviour ClickHouse.Format

    alias ClickHouse.Format.TSV

    @parser TSV.Parser

    ################################
    # ClickHouse.Format Callbacks
    ################################

    @impl ClickHouse.Format
    @spec names() :: [binary()]
    def names, do: ["TabSeparatedWithNamesAndTypes", "TSVWithNamesAndTypes"]

    @impl ClickHouse.Format
    @spec decode(raw :: iodata()) :: {ClickHouse.Result.columns(), ClickHouse.Result.rows()}
    def decode(raw) do
      [names, types | rows] = @parser.parse_string(raw, skip_headers: false)
      columns = build_columns(names, types)
      rows = decode_rows(columns, rows)
      {columns, rows}
    end

    @impl ClickHouse.Format
    @spec encode(ClickHouse.data_types(), rows :: list()) :: iodata()
    def encode(_types, []), do: []

    def encode(_types, [names, types | rows]) do
      [@parser.dump_to_iodata([names, types]), TSV.encode([], rows)]
    end

    def encode(_, _) do
      raise ArgumentError, "missing TSV column names and types"
    end

    ################################
    # Private API
    ################################

    defp build_columns(names, types) do
      types = parse_types(types, [])
      Enum.zip([names, types])
    end

    defp parse_types([], results), do: Enum.reverse(results)

    defp parse_types([type | types], results) do
      type = ClickHouse.DataType.to_internal(type)
      parse_types(types, [type | results])
    end

    defp decode_rows(columns, rows) do
      Enum.map(rows, &decode_row(columns, &1))
    end

    defp decode_row(columns, row) do
      [columns, row]
      |> Enum.zip()
      |> Enum.map(fn {{_name, type}, value} ->
        decode_value(type, value)
      end)
    end

    defguardp is_enum_type(type)
              when is_tuple(type) and elem(type, 0) in [:enum8, :enum16]

    defguardp is_integer_type(type) when type in [:i64, :i32, :i16, :i8, :u64, :u32, :u16, :u8]
    defguardp is_float_type(type) when type in [:f64, :f32]
    defguardp is_ignore_type(type) when type in [:string, :uuid] or is_enum_type(type)

    defguardp is_quoted_type(type)
              when type in [:string, :uuid, :date, :date32, :datetime, :datetime64] or
                     is_enum_type(type)

    defp decode_value(type, value) when is_integer_type(type), do: to_integer(value)
    defp decode_value(type, value) when is_float_type(type), do: to_float(value)
    defp decode_value(type, value) when is_ignore_type(type), do: value

    defp decode_value(:boolean, "true"), do: true
    defp decode_value(:boolean, "false"), do: false

    defp decode_value({:fixed_string, length}, value) do
      Enum.reduce(1..length, value, fn _, string ->
        String.replace(string, "\\0", "", global: false)
      end)
    end

    defp decode_value(:date, value) do
      Date.from_iso8601!(value)
    end

    defp decode_value(:date32, value) do
      Date.from_iso8601!(value)
    end

    defp decode_value(:datetime, value) do
      [date, time] = String.split(value, " ")
      date = Date.from_iso8601!(date)
      time = Time.from_iso8601!(time)
      {:ok, date_time} = DateTime.new(date, time)
      date_time
    end

    defp decode_value(:datetime64, value) do
      [date, time] = String.split(value, " ")
      date = Date.from_iso8601!(date)
      time = Time.from_iso8601!(time)
      {:ok, date_time} = DateTime.new(date, time)
      date_time
    end

    defp decode_value({:nullable, _type}, "\\N"), do: nil
    defp decode_value({:nullable, _type}, "NULL"), do: nil

    defp decode_value({:nullable, type}, value) do
      decode_value(type, value)
    end

    defp decode_value({:low_cardinality, type}, value) do
      decode_value(type, value)
    end

    defp decode_value({:array, :nothing}, _), do: []

    defp decode_value({:array, type}, value) when is_quoted_type(type) do
      value
      |> trim_array()
      |> String.trim_leading("'")
      |> String.trim_trailing("'")
      |> String.split("','")
      |> Enum.map(&decode_value(type, &1))
    end

    defp decode_value({:array, type}, value) when is_integer_type(type) or is_float_type(type) do
      type
      |> to_array(value)
      |> Enum.reject(&is_nil/1)
    end

    defp decode_value({:array, {:array, _} = type}, value) do
      value
      |> trim_array()
      |> String.split("],[")
      |> Enum.map(fn
        "" -> []
        v -> decode_value(type, v)
      end)
    end

    defp decode_value({:array, type}, value) do
      to_array(type, value)
    end

    defp decode_value({{:simple_aggregate_function, _}, type}, value) do
      decode_value(type, value)
    end

    defp decode_value({:tuple, types}, value) do
      value
      |> String.trim_leading("(")
      |> String.trim_trailing(")")
      |> split_tuple_elements()
      |> Enum.zip(types)
      |> Enum.map(fn
        {val, type} when is_quoted_type(type) ->
          val =
            val
            |> String.trim_leading("'")
            |> String.trim_trailing("'")

          decode_value(type, val)

        {val, type} ->
          decode_value(type, val)
      end)
      |> List.to_tuple()
    end

    defp to_integer(""), do: nil
    defp to_integer(value), do: String.to_integer(value)

    defp to_float(""), do: nil
    defp to_float("nan"), do: :nan
    defp to_float("inf"), do: :inf
    defp to_float("-inf"), do: :"-inf"

    defp to_float(value) do
      {float, _} = Float.parse(value)
      float
    end

    defp to_array(type, value) do
      value
      |> trim_array()
      |> String.split(",")
      |> Enum.map(&decode_value(type, &1))
    end

    defp trim_array(value) do
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
    end

    defp split_tuple_elements(value) do
      value
      |> to_charlist()
      |> do_split_tuple_elements()
      |> Enum.map(&to_string/1)
    end

    defp do_split_tuple_elements(value, acc \\ [], elems \\ [], wraps \\ [])

    # Joint base case
    defp do_split_tuple_elements([], [], elems, []), do: Enum.reverse(elems)

    defp do_split_tuple_elements([], acc, elems, []) do
      do_split_tuple_elements([], [], [Enum.reverse(acc) | elems], [])
    end

    # Values are split by a comma outside of any wraps
    defp do_split_tuple_elements([44 | value], acc, elems, []) do
      do_split_tuple_elements(value, [], [Enum.reverse(acc) | elems], [])
    end

    # Handle single quoted values
    defp do_split_tuple_elements([39 | _] = value, acc, elems, wraps) do
      {value, trimmed} = trim_quoted(value)
      do_split_tuple_elements(value, trimmed ++ acc, elems, wraps)
    end

    # Next 3 clauses handle brackets and parantheses
    defp do_split_tuple_elements([c | values], acc, elems, wraps) when c in [40, 91] do
      do_split_tuple_elements(values, [c | acc], elems, [c | wraps])
    end

    defp do_split_tuple_elements([93 | values], acc, elems, [91 | wraps]) do
      do_split_tuple_elements(values, [93 | acc], elems, wraps)
    end

    defp do_split_tuple_elements([41 | values], acc, elems, [40 | wraps]) do
      do_split_tuple_elements(values, [41 | acc], elems, wraps)
    end

    defp do_split_tuple_elements([c | values], acc, elems, wraps) do
      do_split_tuple_elements(values, [c | acc], elems, wraps)
    end

    defp trim_quoted(chars, open \\ false, acc \\ [])

    # Treat escaped single quote like any other character
    defp trim_quoted([92, 39 | chars], open, acc), do: trim_quoted(chars, open, [39, 92 | acc])
    defp trim_quoted([39 | chars], false, acc), do: trim_quoted(chars, true, [39 | acc])
    defp trim_quoted([39 | chars], true, acc), do: {chars, [39 | acc]}
    defp trim_quoted([c | chars], open, acc), do: trim_quoted(chars, open, [c | acc])
  end
end
