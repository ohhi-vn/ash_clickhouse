defmodule AshClickhouse.DataLayer.Record do
  @moduledoc """
  Decodes raw ClickHouse rows/maps into Ash resource structs.

  Extracted from `AshClickhouse.DataLayer` so the row→record decoding logic
  (UUID/atom type handling, column mapping, attribute-type-aware value
  decoding) lives in one focused module.
  """

  alias Ash.Resource.Info
  alias AshClickhouse.DataLayer.Types

  @doc """
  Decodes a single value list (positional, aligned to `columns`) into a record.

  A result column that carries a calculation is placed in the record's
  `calculations` map under the calculation's name; the remaining columns still
  decode positionally against the attribute list.
  """
  @spec to_ash_record(maybe_improper_list(), module(), maybe_improper_list() | nil, map()) ::
          struct()
  def to_ash_record(row, resource, columns, calculations \\ %{})

  def to_ash_record(row, resource, columns, _calculations)
      when is_list(row) and columns in [nil, []],
      do: to_ash_record(row, resource)

  def to_ash_record(row, resource, columns, calculations)
      when is_list(row) and is_list(columns) and columns != [] do
    {attribute_values, calculation_values} =
      row
      |> Enum.zip(columns)
      |> Enum.split_with(fn {_value, column} ->
        not calculation_column?(column, calculations)
      end)

    record_map =
      attribute_values
      |> Enum.reduce(%{}, fn {value, column}, acc ->
        Map.put(acc, to_string(column_name(column)), value)
      end)

    calculation_map =
      calculation_values
      |> Enum.reduce(%{}, fn {value, column}, acc ->
        name = column_name(column)
        metadata = Map.get(calculations, to_string(name), %{})

        Map.put(acc, Map.get(metadata, :name, name), decode_calculation(value, metadata))
      end)

    build_record(record_map, resource, calculation_map)
  end

  @doc """
  Decodes a value list positionally against the resource's attribute
  declaration order (used by the streaming path when no column names are known).
  """
  @spec to_ash_record(maybe_improper_list() | map(), module()) :: struct()
  def to_ash_record(row, resource) when is_list(row) do
    attr_names = resource |> Info.attributes() |> Enum.map(& &1.name)

    record_map =
      row
      |> Enum.zip(attr_names)
      |> Enum.reduce(%{}, fn {value, name}, acc -> Map.put(acc, to_string(name), value) end)

    build_record(record_map, resource, %{})
  end

  # Map clause (same arity, separate guard): decodes a map of string/atom
  # column values into a record.
  def to_ash_record(row, resource) when is_map(row) do
    build_record(row, resource, %{})
  end

  @doc """
  Converts a string to an existing atom, leaving it as a string otherwise.
  """
  @spec to_existing_atom(String.t()) :: atom() | String.t()
  def to_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  # Builds the resource struct from a map of decoded column values, decoding
  # each attribute with its own type and attaching the calculated values.
  @spec build_record(map(), module(), map()) :: struct()
  defp build_record(row, resource, calculation_map) do
    uuid_fields = Types.uuid_attribute_names(resource)
    atom_fields = Types.atom_attribute_names(resource)

    attrs =
      resource
      |> Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        value = Map.get(row, attr.name)
        value = if is_nil(value), do: Map.get(row, to_string(attr.name)), else: value

        decoded =
          cond do
            attr.name in uuid_fields and is_binary(value) and byte_size(value) == 16 ->
              case Types.uuid_binary_to_string(value) do
                {:ok, str} -> str
                _ -> value
              end

            attr.name in atom_fields and is_binary(value) ->
              to_existing_atom(value)

            true ->
              Types.decode_value(value, attr)
          end

        Map.put(acc, attr.name, decoded)
      end)

    struct(resource, Map.put(attrs, :calculations, calculation_map))
  end

  # The name of a result column. An expression entry in the select list is a
  # `{name, sql}` pair; a plain column is an atom or a string.
  @spec column_name(term()) :: String.t() | atom()
  defp column_name({name, _sql}), do: name
  defp column_name(name), do: name

  # A column carries a calculation when the query pushed that calculation down
  # into the select list.
  @spec calculation_column?(term(), map()) :: boolean()
  defp calculation_column?(column, calculations)
       when is_map(calculations) and map_size(calculations) > 0 do
    Map.has_key?(calculations, to_string(column_name(column)))
  end

  defp calculation_column?(_column, _calculations), do: false

  # Decodes a calculated value using the calculation's declared type, so a
  # numeric calculation yields a number rather than a string.
  @spec decode_calculation(term(), map()) :: term()
  defp decode_calculation(value, %{type: type}) when not is_nil(type) do
    Types.decode_value(value, %{type: type})
  end

  defp decode_calculation(value, _metadata), do: value
end
