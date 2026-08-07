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
  """
  @spec to_ash_record(maybe_improper_list(), module(), maybe_improper_list()) :: struct()
  def to_ash_record(row, resource, columns)
      when is_list(row) and is_list(columns) and columns != [] do
    record_map =
      row
      |> Enum.zip(columns)
      |> Enum.reduce(%{}, fn {value, col}, acc ->
        Map.put(acc, to_string(col), value)
      end)

    to_ash_record(record_map, resource)
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

    to_ash_record(record_map, resource)
  end

  # Map clause (same arity, separate guard): decodes a map of string/atom
  # column values into a record.
  def to_ash_record(row, resource) when is_map(row) do
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

    struct(resource, attrs)
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
end
