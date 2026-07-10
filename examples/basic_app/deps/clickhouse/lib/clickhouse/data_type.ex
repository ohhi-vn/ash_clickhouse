defmodule ClickHouse.DataType do
  @moduledoc """
  Functions for working with ClickHouse data types.
  """

  @type_mappings [
    {"Int64", :i64},
    {"Int32", :i32},
    {"Int16", :i16},
    {"Int8", :i8},
    {"Bool", :boolean},
    {"UInt64", :u64},
    {"UInt32", :u32},
    {"UInt16", :u16},
    {"UInt8", :u8},
    {"Float64", :f64},
    {"Float32", :f32},
    {"String", :string},
    {"UUID", :uuid},
    {"Date", :date},
    {"DateTime", :datetime},
    {"Nothing", :nothing}
  ]

  @simple_aggregate_function_mappings [
    {"any", :any},
    {"anyLast", :any_last},
    {"min", :min},
    {"max", :max},
    {"sum", :sum},
    {"sumWithOverflow", :sum_with_overflow},
    {"groupBitAnd", :group_bit_and},
    {"groupBitOr", :group_bit_or},
    {"groupBitXor", :group_bit_xor},
    {"groupArrayArray", :group_array_array},
    {"groupUniqArrayArray", :group_uniq_array_array},
    {"sumMap", :sum_map},
    {"minMap", :min_map},
    {"maxMap", :max_map}
  ]

  ################################
  # Public API
  ################################

  @doc """
  Converts the given internal type into an external representation.
  """
  @spec to_external(ClickHouse.data_type()) :: String.t()
  for {external_type, internal_type} <- @type_mappings do
    def to_external(unquote(internal_type)) do
      unquote(external_type)
    end
  end

  def to_external(:date32), do: "Date32"
  def to_external(:datetime64), do: "DateTime64"

  def to_external({:array, type}) do
    <<"Array(", to_external(type)::bytes, ")">>
  end

  def to_external({:nullable, type}) do
    <<"Nullable(", to_external(type)::bytes, ")">>
  end

  def to_external({:low_cardinality, type}) do
    <<"LowCardinality(", to_external(type)::bytes, ")">>
  end

  def to_external({:fixed_string, type}) do
    <<"FixedString(", to_external(type)::bytes, ")">>
  end

  def to_external({:enum8, mapping}) do
    <<"Enum8(", to_external_enum(mapping)::bytes, ")">>
  end

  def to_external({:enum16, mapping}) do
    <<"Enum16(", to_external_enum(mapping)::bytes, ")">>
  end

  def to_external({:tuple, types}) do
    "Tuple(#{Enum.map_join(types, ", ", &to_external/1)})"
  end

  @doc """
  Converts the given external type into an internal representation.
  """
  @spec to_internal(String.t()) :: ClickHouse.data_type()
  for {external_type, internal_type} <- @type_mappings do
    def to_internal(unquote(external_type)) do
      unquote(internal_type)
    end
  end

  def to_internal("Date32") do
    :date32
  end

  def to_internal(<<"DateTime64(", _rest::binary>>) do
    :datetime64
  end

  def to_internal(<<"Nullable(", type::binary>>) do
    rest_type =
      type
      |> String.replace_suffix(")", "")
      |> to_internal()

    {:nullable, rest_type}
  end

  def to_internal(<<"LowCardinality(", type::binary>>) do
    rest_type =
      type
      |> String.replace_suffix(")", "")
      |> to_internal()

    {:low_cardinality, rest_type}
  end

  def to_internal(<<"FixedString(", rest::binary>>) do
    {length, _rest} = Integer.parse(rest)
    {:fixed_string, length}
  end

  def to_internal(<<"Array(", type::binary>>) do
    rest_type =
      type
      |> String.replace_suffix(")", "")
      |> to_internal()

    {:array, rest_type}
  end

  def to_internal(<<"Tuple(", rest::binary>>) do
    types =
      rest
      |> String.replace_suffix(")", "")
      |> parse_tuple_types()

    {:tuple, types}
  end

  def to_internal(<<"Enum8(", type::binary>>) do
    enums = to_internal_enum(type)
    {:enum8, enums}
  end

  def to_internal(<<"Enum16(", type::binary>>) do
    enums = to_internal_enum(type)
    {:enum16, enums}
  end

  def to_internal(<<"SimpleAggregateFunction(", rest::binary>>) do
    [function_type, rest] = String.split(rest, ",")
    function_type = to_internal_aggregate_type(function_type)

    rest_type =
      rest
      |> String.split(",")
      |> List.last()
      |> String.replace_suffix(")", "")
      |> String.trim()
      |> to_internal()

    {{:simple_aggregate_function, function_type}, rest_type}
  end

  @doc """
  Encodes the provided data using the `ClickHouse.DataType.Encodable` protocol.
  """
  @spec encode(any()) :: iodata()
  defdelegate encode(data), to: ClickHouse.DataType.Encodable

  ################################
  # Private API
  ################################

  defp to_internal_enum(type) do
    type
    |> String.replace_suffix(")", "")
    |> String.split(", ")
    |> Enum.map(&String.split(&1, " = "))
    |> Enum.map(fn [name, value] ->
      name =
        name
        |> String.replace("\\'", "")
        |> String.replace("'", "")

      {name, String.to_integer(value)}
    end)
    |> Enum.into(%{})
  end

  defp to_external_enum(mapping) do
    mapping
    |> Enum.map(fn {k, v} -> {v, k} end)
    |> Enum.sort(fn {v1, _}, {v2, _} -> v1 > v2 end)
    |> Enum.map_join(", ", fn {v, k} ->
      <<"'", k::bytes, "'", " = ", to_string(v)::bytes>>
    end)
  end

  for {external_type, internal_type} <- @simple_aggregate_function_mappings do
    defp to_internal_aggregate_type(unquote(external_type)) do
      unquote(internal_type)
    end
  end

  # This function is **TRICKY** because it aims to parse types from both named
  # and unnamed tuples. We leverage charlists here because it ends up being more
  # manageable than manipulating binaries. Code is thoroughly commented to
  # compensate for lack of readability.
  defp parse_tuple_types(raw) do
    raw
    |> to_charlist()
    |> split_raw_elements()
    |> Enum.map(fn element ->
      element
      |> element_type()
      |> to_string()
      |> to_internal()
    end)
  end

  # Splits raw tuple config into one charlist per element
  defp split_raw_elements(raw, acc \\ [], elems \\ [], parantheses \\ 0)

  # First two clauses form a joint base case
  defp split_raw_elements([], [], elems, 0), do: Enum.reverse(elems)

  defp split_raw_elements([], acc, elems, 0) do
    split_raw_elements([], [], [Enum.reverse(acc) | elems])
  end

  # Elements are split on ", " when not wrapped in quotes, ticks or parantheses
  defp split_raw_elements([44, 32 | raw], acc, elems, 0) do
    split_raw_elements(raw, [], [Enum.reverse(acc) | elems], 0)
  end

  # Handles quoted chunks
  defp split_raw_elements([c | _] = raw, acc, elems, par) when c in [34, 96] do
    {raw, trimmed} = trim_quoted(raw)
    split_raw_elements(raw, trimmed ++ acc, elems, par)
  end

  # Next two clauses handle parantheses outside of quotes
  defp split_raw_elements([40 | raw], acc, elems, par) do
    split_raw_elements(raw, [40 | acc], elems, par + 1)
  end

  defp split_raw_elements([41 | raw], acc, elems, par) do
    split_raw_elements(raw, [41 | acc], elems, par - 1)
  end

  defp split_raw_elements([c | raw], acc, elems, par) do
    split_raw_elements(raw, [c | acc], elems, par)
  end

  # Effectively trims names from tuple config if they're present
  defp element_type(raw, acc \\ [], parantheses \\ 0)

  # If the first charcter is a quote or tick, we know it's a column name so we
  # trim the entire thing
  defp element_type([c | _] = raw, _, 0) when c in [34, 96] do
    {[32 | raw], _} = trim_quoted(raw)
    raw
  end

  # If the first character is a space outside of parantheses, we know that
  # everything up to this point has been a column name
  defp element_type([32 | raw], _, 0), do: raw

  # If there are no more characters, there were no names so the accumulator
  # represents the type
  defp element_type([], acc, 0), do: Enum.reverse(acc)

  # The next two clauses handle parantheses outside of quotes
  defp element_type([40 | raw], acc, par), do: element_type(raw, [40 | acc], par + 1)
  defp element_type([41 | raw], acc, par), do: element_type(raw, [41 | acc], par - 1)
  defp element_type([c | raw], acc, par), do: element_type(raw, [c | acc], par)

  defp trim_quoted(chars, c \\ nil, acc \\ [])
  defp trim_quoted([c | chars], nil, acc), do: trim_quoted(chars, c, [c | acc])

  # This clause skips escaped characters
  defp trim_quoted([92, x | chars], c, acc), do: trim_quoted(chars, c, [x, 92 | acc])
  defp trim_quoted([c | chars], c, acc), do: {chars, [c | acc]}
  defp trim_quoted([x | chars], c, acc), do: trim_quoted(chars, c, [x | acc])
end
