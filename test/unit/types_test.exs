defmodule AshClickhouse.TypesTest do
  @moduledoc "Unit tests for AshClickhouse.DataLayer.Types."
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.Types

  describe "ash_type_to_clickhouse/1" do
    test "maps common atom types" do
      assert Types.ash_type_to_clickhouse(:uuid) == "UUID"
      assert Types.ash_type_to_clickhouse(:integer) == "Int64"
      assert Types.ash_type_to_clickhouse(:string) == "String"
      assert Types.ash_type_to_clickhouse(:boolean) == "UInt8"
      assert Types.ash_type_to_clickhouse(:float) == "Float64"
      assert Types.ash_type_to_clickhouse(:date) == "Date"
    end

    test "maps collection types" do
      assert Types.ash_type_to_clickhouse({:array, :string}) == "Array(String)"
      assert Types.ash_type_to_clickhouse({:map, :string, :integer}) == "Map(String, Int64)"
      assert Types.ash_type_to_clickhouse(:list) == "Array(String)"
    end

    test "falls back to String for unknown types" do
      assert Types.ash_type_to_clickhouse(:unknown_thing) == "String"
    end
  end

  describe "uuid round trip" do
    test "string <-> binary" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      {:ok, bin} = Types.uuid_string_to_binary(uuid)
      assert byte_size(bin) == 16
      {:ok, back} = Types.uuid_binary_to_string(bin)
      assert back == uuid
    end

    test "rejects malformed uuid strings" do
      assert :error = Types.uuid_string_to_binary("not-a-uuid")
      assert :error = Types.uuid_binary_to_string("tooshort")
    end

    test "uuid_like_string?/1" do
      assert Types.uuid_like_string?("550e8400-e29b-41d4-a716-446655440000")
      refute Types.uuid_like_string?("550e8400-e29b-41d4-a716")
    end
  end
end
