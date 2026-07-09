defmodule AshClickhouse.TypesExtraTest do
  @moduledoc "Additional unit tests for AshClickhouse.DataLayer.Types."
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.Types

  describe "ash_type_to_clickhouse/1 (module-based Ash types)" do
    test "maps Ash.Type.* modules" do
      assert Types.ash_type_to_clickhouse(Ash.Type.UUID) == "UUID"
      assert Types.ash_type_to_clickhouse(Ash.Type.Integer) == "Int64"
      assert Types.ash_type_to_clickhouse(Ash.Type.Float) == "Float64"
      assert Types.ash_type_to_clickhouse(Ash.Type.Boolean) == "UInt8"
      assert Types.ash_type_to_clickhouse(Ash.Type.String) == "String"
      assert Types.ash_type_to_clickhouse(Ash.Type.Atom) == "String"
      assert Types.ash_type_to_clickhouse(Ash.Type.CiString) == "String"
      assert Types.ash_type_to_clickhouse(Ash.Type.DateTime) == "DateTime64(6)"
      assert Types.ash_type_to_clickhouse(Ash.Type.Date) == "Date"
      assert Types.ash_type_to_clickhouse(Ash.Type.Time) == "String"
      assert Types.ash_type_to_clickhouse(Ash.Type.Decimal) == "Decimal(38, 10)"
      assert Types.ash_type_to_clickhouse(Ash.Type.Binary) == "String"
      assert Types.ash_type_to_clickhouse(Ash.Type.Map) == "Map(String, String)"
    end

    test "maps datetime usec variants" do
      assert Types.ash_type_to_clickhouse(:utc_datetime_usec) == "DateTime64(6)"
      assert Types.ash_type_to_clickhouse(:naive_datetime_usec) == "DateTime64(6)"
      assert Types.ash_type_to_clickhouse(:time_usec) == "String"
    end

    test "maps composite and set/tuple types" do
      assert Types.ash_type_to_clickhouse({:set, :integer}) == "Array(Int64)"
      assert Types.ash_type_to_clickhouse({:tuple, [:integer, :string]}) == "Tuple(Int64, String)"
      assert Types.ash_type_to_clickhouse({:array, :integer}) == "Array(Int64)"
      assert Types.ash_type_to_clickhouse({:map, :integer, :string}) == "Map(Int64, String)"
    end
  end

  describe "resolve_attr_type/1" do
    test "resolves atom and module types" do
      assert Types.resolve_attr_type(%{type: :integer}) == "Int64"
      assert Types.resolve_attr_type(%{type: Ash.Type.UUID}) == "UUID"
    end

    test "honours decimal constraints" do
      assert Types.resolve_attr_type(%{type: :decimal, constraints: [precision: 10, scale: 2]}) ==
               "Decimal(10, 2)"
    end

    test "falls back to String for unknown types" do
      assert Types.resolve_attr_type(%{type: :does_not_exist}) == "String"
    end
  end

  describe "attr_type_map/1" do
    defmodule AttrMapResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("attr_map")
        repo(AshClickhouse.TestRepo)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string)
        attribute(:age, :integer)
        attribute(:score, :decimal, constraints: [precision: 10, scale: 2])
      end
    end

    test "returns atom and string keys for every attribute" do
      map = Types.attr_type_map(AttrMapResource)
      assert Map.get(map, :id) == "UUID"
      assert Map.get(map, "name") == "String"
      assert Map.get(map, :age) == "Int64"
      assert Map.get(map, :score) == "Decimal(10, 2)"
    end
  end

  describe "decode_value/2" do
    test "parses integer strings" do
      assert Types.decode_value("42", %{type: :integer}) == 42
      assert Types.decode_value(42, %{type: :integer}) == 42
      assert Types.decode_value(nil, %{type: :integer}) == nil
    end

    test "parses float strings" do
      assert Types.decode_value("3.14", %{type: :float}) == 3.14
      assert Types.decode_value(2, %{type: :float}) == 2.0
    end

    test "parses boolean values from ints, atoms and strings" do
      assert Types.decode_value(1, %{type: :boolean}) == true
      assert Types.decode_value(0, %{type: :boolean}) == false
      assert Types.decode_value("true", %{type: :boolean}) == true
      assert Types.decode_value("0", %{type: :boolean}) == false
      assert Types.decode_value(true, %{type: :boolean}) == true
    end

    test "parses decimal strings" do
      assert %Decimal{} = Types.decode_value("1.5", %{type: :decimal})

      assert Types.decode_value(%Decimal{coef: 15, exp: -1}, %{type: :decimal}) == %Decimal{
               coef: 15,
               exp: -1
             }
    end

    test "passes through values it does not know how to decode" do
      assert Types.decode_value("hello", %{type: :string}) == "hello"
    end
  end

  describe "encode_value/2 edge cases" do
    test "encodes nil maps and lists as nil" do
      assert Types.encode_value(nil, %{type: :map}) == nil
      assert Types.encode_value(nil, %{type: :array}) == nil
    end

    test "passes through non-composite values for composite types" do
      assert Types.encode_value("not a map", %{type: :map}) == "not a map"
      assert Types.encode_value("not a list", %{type: :array}) == "not a list"
    end
  end
end
