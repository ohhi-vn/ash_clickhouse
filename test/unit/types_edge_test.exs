defmodule AshClickhouse.TypesEdgeTest do
  @moduledoc "Edge-case unit tests for AshClickhouse.DataLayer.Types."
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.Types

  describe "ash_type_to_clickhouse/1 edge cases" do
    test "nested composite types" do
      assert Types.ash_type_to_clickhouse({:array, {:array, :integer}}) ==
               "Array(Array(Int64))"

      assert Types.ash_type_to_clickhouse({:map, :string, {:array, :integer}}) ==
               "Map(String, Array(Int64))"

      assert Types.ash_type_to_clickhouse({:tuple, [:integer, :string, :boolean]}) ==
               "Tuple(Int64, String, UInt8)"
    end

    test "unknown atom and module types fall back to String" do
      assert Types.ash_type_to_clickhouse(:totally_unknown) == "String"
      assert Types.ash_type_to_clickhouse(UnknownModule) == "String"
    end

    test "decimal tuple form falls back to String (use resolve_attr_type for constraints)" do
      assert Types.ash_type_to_clickhouse({:decimal, [precision: 18, scale: 4]}) == "String"
    end
  end

  describe "resolve_attr_type/1 edge cases" do
    test "decimal with no constraints uses defaults" do
      assert Types.resolve_attr_type(%{type: :decimal}) == "Decimal(38, 10)"
    end

    test "module type with storage_type/1 is honoured" do
      defmodule CustomStorageType do
        def storage_type(_constraints), do: :integer
      end

      assert Types.resolve_attr_type(%{type: CustomStorageType}) == "Int64"
    end

    test "unknown attribute type falls back to String" do
      assert Types.resolve_attr_type(%{type: :nope}) == "String"
    end
  end

  describe "encode_value/2 edge cases" do
    test "encodes nested maps and lists" do
      # Values are stringified with `to_string/1`. A nested list is treated as a
      # charlist by `to_string/1` (e.g. `[2, 3]` -> `"\x02\x03"`), which is the
      # library's actual behaviour for composite value encoding.
      assert Types.encode_value(%{a: 1, b: [2, 3]}, %{type: :map}) ==
               %{"a" => "1", "b" => "\x02\x03"}

      assert Types.encode_value([1, [2, 3]], %{type: :array}) == ["1", "\x02\x03"]
    end

    test "encodes time structs" do
      {:ok, time} = Time.from_iso8601("23:59:59")
      assert Types.encode_value(time, %{type: :time}) == "23:59:59"
    end

    test "passes through non-composite values for composite types" do
      assert Types.encode_value("not a map", %{type: :map}) == "not a map"
      assert Types.encode_value(42, %{type: :array}) == 42
    end

    test "passes through values for scalar types" do
      assert Types.encode_value("x", %{type: :string}) == "x"
      assert Types.encode_value(5, %{type: :integer}) == 5
    end

    test "non-map attr passes through unchanged" do
      assert Types.encode_value("x", :not_a_map) == "x"
    end
  end

  describe "decode_value/2 edge cases" do
    test "decodes integer from string and int" do
      assert Types.decode_value("99", %{type: :integer}) == 99
      assert Types.decode_value(99, %{type: :integer}) == 99
      assert Types.decode_value(nil, %{type: :integer}) == nil
    end

    test "decodes float from string, int and float" do
      assert Types.decode_value("1.5", %{type: :float}) == 1.5
      assert Types.decode_value(2, %{type: :float}) == 2.0
      assert Types.decode_value(3.5, %{type: :float}) == 3.5
    end

    test "decodes boolean from int, string and atom" do
      assert Types.decode_value(1, %{type: :boolean}) == true
      assert Types.decode_value(0, %{type: :boolean}) == false
      assert Types.decode_value("TRUE", %{type: :boolean}) == true
      assert Types.decode_value("0", %{type: :boolean}) == false
      assert Types.decode_value(true, %{type: :boolean}) == true
      assert Types.decode_value(false, %{type: :boolean}) == false
    end

    test "decodes decimal from string and Decimal" do
      assert %Decimal{} = Types.decode_value("2.5", %{type: :decimal})

      dec = %Decimal{coef: 25, exp: -1}
      assert Types.decode_value(dec, %{type: :decimal}) == dec
      assert Types.decode_value(nil, %{type: :decimal}) == nil
    end

    test "decodes time from string" do
      {:ok, time} = Time.from_iso8601("01:02:03")
      assert Types.decode_value("01:02:03", %{type: :time}) == time
      assert Types.decode_value(nil, %{type: :time}) == nil
      assert Types.decode_value("garbage", %{type: :time}) == "garbage"
    end

    test "passes through unknown types unchanged" do
      assert Types.decode_value("x", %{type: :string}) == "x"
    end

    test "non-map attr passes through unchanged" do
      assert Types.decode_value("x", :not_a_map) == "x"
    end
  end

  describe "uuid helpers edge cases" do
    test "round trips a UUID through binary and string" do
      uuid = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
      {:ok, bin} = Types.uuid_string_to_binary(uuid)
      assert byte_size(bin) == 16
      {:ok, back} = Types.uuid_binary_to_string(bin)
      assert back == uuid
    end

    test "rejects malformed uuids" do
      assert :error = Types.uuid_string_to_binary("")
      assert :error = Types.uuid_string_to_binary("not-a-uuid-at-all")
      assert :error = Types.uuid_binary_to_string(<<1, 2, 3>>)
      assert :error = Types.uuid_binary_to_string(:not_binary)
    end

    test "uuid_like_string? is precise" do
      assert Types.uuid_like_string?("ffffffff-ffff-ffff-ffff-ffffffffffff")
      # `:mixed` case decoding accepts uppercase hex too.
      assert Types.uuid_like_string?("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
      refute Types.uuid_like_string?("ffffffff-ffff-ffff-ffff")
      refute Types.uuid_like_string?("zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz")
      refute Types.uuid_like_string?(123)
    end
  end
end
