defmodule AshClickhouse.DataLayer.Types do
  @moduledoc """
  Mapping between Ash attribute types and ClickHouse column types.

  ClickHouse is a strongly-typed columnar store. When generating `CREATE TABLE`
  statements and when encoding query parameters, the data layer needs to know
  the ClickHouse type that corresponds to each Ash attribute.

  The mapping here favours ClickHouse types that are safe and broadly useful:

  | Ash type | ClickHouse type |
  | --- | --- |
  | `:uuid` | `UUID` |
  | `:string` / `:atom` / `:ci_string` | `String` |
  | `:integer` | `Int64` |
  | `:float` | `Float64` |
  | `:boolean` | `UInt8` |
  | `:utc_datetime` / `:naive_datetime` | `DateTime` / `DateTime64` |
  | `:date` | `Date` |
  | `:time` | `String` |
  | `:decimal` | `Decimal` |
  | `:map` | `Map(String, String)` |
  | `:array` / `:list` | `Array(String)` |
  """

  alias Ash.Type

  @doc """
  Maps an Ash attribute type to a ClickHouse column type string.
  """
  @spec ash_type_to_clickhouse(atom() | tuple() | module()) :: String.t()
  def ash_type_to_clickhouse(type)

  # Module-based Ash types
  def ash_type_to_clickhouse(Type.UUID), do: "UUID"
  def ash_type_to_clickhouse(Type.Integer), do: "Int64"
  def ash_type_to_clickhouse(Type.Float), do: "Float64"
  def ash_type_to_clickhouse(Type.Boolean), do: "UInt8"
  def ash_type_to_clickhouse(Type.String), do: "String"
  def ash_type_to_clickhouse(Type.Atom), do: "String"
  def ash_type_to_clickhouse(Type.CiString), do: "String"
  def ash_type_to_clickhouse(Type.DateTime), do: "DateTime64(6)"
  def ash_type_to_clickhouse(Type.Date), do: "Date"
  def ash_type_to_clickhouse(Type.Time), do: "String"
  def ash_type_to_clickhouse(Type.Decimal), do: "Decimal(38, 10)"
  def ash_type_to_clickhouse(Type.Binary), do: "String"
  def ash_type_to_clickhouse(Type.Map), do: "Map(String, String)"

  # Atom-based types
  def ash_type_to_clickhouse(:uuid), do: "UUID"
  def ash_type_to_clickhouse(:integer), do: "Int64"
  def ash_type_to_clickhouse(:float), do: "Float64"
  def ash_type_to_clickhouse(:double), do: "Float64"
  def ash_type_to_clickhouse(:boolean), do: "UInt8"
  def ash_type_to_clickhouse(:string), do: "String"
  def ash_type_to_clickhouse(:text), do: "String"
  def ash_type_to_clickhouse(:atom), do: "String"
  def ash_type_to_clickhouse(:ci_string), do: "String"
  def ash_type_to_clickhouse(:utc_datetime), do: "DateTime64(6)"
  def ash_type_to_clickhouse(:utc_datetime_usec), do: "DateTime64(6)"
  def ash_type_to_clickhouse(:naive_datetime), do: "DateTime64(6)"
  def ash_type_to_clickhouse(:naive_datetime_usec), do: "DateTime64(6)"
  def ash_type_to_clickhouse(:date), do: "Date"
  def ash_type_to_clickhouse(:time), do: "String"
  def ash_type_to_clickhouse(:time_usec), do: "String"
  def ash_type_to_clickhouse(:decimal), do: "Decimal(38, 10)"
  def ash_type_to_clickhouse(:binary), do: "String"
  def ash_type_to_clickhouse(:map), do: "Map(String, String)"

  # Collection types
  def ash_type_to_clickhouse(:list), do: "Array(String)"
  def ash_type_to_clickhouse(:array), do: "Array(String)"

  def ash_type_to_clickhouse({:array, element_type}) do
    "Array(#{ash_type_to_clickhouse(element_type)})"
  end

  def ash_type_to_clickhouse({:map, key_type, value_type}) do
    "Map(#{ash_type_to_clickhouse(key_type)}, #{ash_type_to_clickhouse(value_type)})"
  end

  def ash_type_to_clickhouse({:set, element_type}) do
    "Array(#{ash_type_to_clickhouse(element_type)})"
  end

  def ash_type_to_clickhouse({:tuple, element_types}) when is_list(element_types) do
    inner = element_types |> Enum.map(&ash_type_to_clickhouse/1) |> Enum.join(", ")
    "Tuple(#{inner})"
  end

  # Fallback
  def ash_type_to_clickhouse(_), do: "String"

  @doc """
  Resolves the ClickHouse type for an Ash attribute struct, preferring the
  attribute's `storage_type/1` when available.
  """
  @spec resolve_attr_type(map()) :: String.t()
  def resolve_attr_type(attr) do
    if is_atom(attr.type) and function_exported?(attr.type, :storage_type, 1) do
      ash_type_to_clickhouse(attr.type.storage_type([]))
    else
      ash_type_to_clickhouse(attr.type)
    end
  end

  @doc """
  Returns the set of attribute names (atom and string) that are UUID-typed.
  """
  @spec uuid_attribute_names(module()) :: MapSet.t()
  def uuid_attribute_names(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr ->
      case attr.type do
        Type.UUID -> true
        :uuid -> true
        _ -> false
      end
    end)
    |> Enum.flat_map(fn attr -> [attr.name, to_string(attr.name)] end)
    |> MapSet.new()
  end

  @doc """
  Returns the set of attribute names (atom) that are Atom-typed.
  """
  @spec atom_attribute_names(module()) :: MapSet.t(atom())
  def atom_attribute_names(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr ->
      case attr.type do
        Type.Atom -> true
        :atom -> true
        _ -> false
      end
    end)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  @doc """
  Builds a map of attribute name => ClickHouse type string for a resource.
  """
  @spec attr_type_map(module()) :: %{(atom() | String.t()) => String.t()}
  def attr_type_map(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce(%{}, fn attr, acc ->
      type = resolve_attr_type(attr)

      acc
      |> Map.put(attr.name, type)
      |> Map.put(to_string(attr.name), type)
    end)
  end

  @doc """
  Converts a 36-character UUID string to its 16-byte binary form for ClickHouse.
  """
  @spec uuid_string_to_binary(String.t()) :: {:ok, binary()} | :error
  def uuid_string_to_binary(value) when is_binary(value) and byte_size(value) == 36 do
    case String.split(value, "-") do
      [a, b, c, d, e] ->
        hex = a <> b <> c <> d <> e

        case Base.decode16(hex, case: :mixed) do
          {:ok, binary} when byte_size(binary) == 16 -> {:ok, binary}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def uuid_string_to_binary(_), do: :error

  @doc """
  Converts a 16-byte UUID binary to its canonical 36-character string form.
  """
  @spec uuid_binary_to_string(binary()) :: {:ok, String.t()} | :error
  def uuid_binary_to_string(value) when is_binary(value) and byte_size(value) == 16 do
    <<a::32, b::16, c::16, d::16, e::48>> = value

    {:ok,
     String.downcase(
       "#{format_hex(a, 8)}-#{format_hex(b, 4)}-#{format_hex(c, 4)}-#{format_hex(d, 4)}-#{format_hex(e, 12)}"
     )}
  end

  def uuid_binary_to_string(_), do: :error

  defp format_hex(value, len) do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(len, "0")
  end

  @doc """
  Returns true if the given binary looks like a canonical UUID string.
  """
  @spec uuid_like_string?(term()) :: boolean()
  def uuid_like_string?(value) when is_binary(value) and byte_size(value) == 36 do
    case String.split(value, "-") do
      [a, b, c, d, e]
      when byte_size(a) == 8 and byte_size(b) == 4 and byte_size(c) == 4 and byte_size(d) == 4 and
             byte_size(e) == 12 ->
        hex = a <> b <> c <> d <> e
        match?({:ok, <<_::16-binary>>}, Base.decode16(hex, case: :mixed))

      _ ->
        false
    end
  end

  def uuid_like_string?(_), do: false
end
