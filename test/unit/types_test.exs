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

  describe "encode_value/2 and decode_value/2" do
    test "stringifies map values for Map(String, String)" do
      attr = %{type: :map}
      assert Types.encode_value(%{a: 1, b: 2}, attr) == %{"a" => "1", "b" => "2"}
    end

    test "stringifies list elements for Array(String)" do
      attr = %{type: :array}
      assert Types.encode_value([1, 2, 3], attr) == ["1", "2", "3"]
    end

    test "converts Time to its string form" do
      attr = %{type: :time}
      {:ok, time} = Time.from_iso8601("12:34:56")
      assert Types.encode_value(time, attr) == "12:34:56"
    end

    test "passes through non-composite values unchanged" do
      assert Types.encode_value(42, %{type: :integer}) == 42
      assert Types.encode_value("x", %{type: :string}) == "x"
    end

    test "decodes time strings back into Time structs" do
      attr = %{type: :time}
      {:ok, time} = Time.from_iso8601("12:34:56")
      assert Types.decode_value("12:34:56", attr) == time
    end
  end

  describe "attribute name helpers" do
    defmodule NameHelperResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("name_helper")
        repo(AshClickhouse.TestRepo)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:status, :atom)
        attribute(:tags, {:array, :string})
      end
    end

    test "uuid_attribute_names/1" do
      names = Types.uuid_attribute_names(NameHelperResource)
      assert MapSet.member?(names, :id)
      assert MapSet.member?(names, "id")
    end

    test "atom_attribute_names/1" do
      names = Types.atom_attribute_names(NameHelperResource)
      assert MapSet.member?(names, :status)
      refute MapSet.member?(names, :id)
    end
  end

  test "string <-> binary" do
    uuid = "550E8400-E29B-41D4-A716-446655440000"
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
