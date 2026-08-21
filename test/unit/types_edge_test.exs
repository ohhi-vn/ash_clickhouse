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

    test "every supported scalar atom type maps to its ClickHouse type" do
      assert Types.ash_type_to_clickhouse(:double) == "Float64"
      assert Types.ash_type_to_clickhouse(:text) == "String"
      assert Types.ash_type_to_clickhouse(:atom) == "String"
      assert Types.ash_type_to_clickhouse(:ci_string) == "String"
      assert Types.ash_type_to_clickhouse(:naive_datetime) == "DateTime64(6)"
      assert Types.ash_type_to_clickhouse(:time) == "String"
      assert Types.ash_type_to_clickhouse(:decimal) == "Decimal(38, 10)"
      assert Types.ash_type_to_clickhouse(:binary) == "String"
      assert Types.ash_type_to_clickhouse(:array) == "Array(String)"
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

    test "encodes via module Ash types and tuple/alias forms" do
      assert Types.encode_value(%{a: 1}, %{type: Ash.Type.Map}) == %{"a" => "1"}
      assert Types.encode_value(%{a: 1}, %{type: {:map, :string, :integer}}) == %{"a" => "1"}
      assert Types.encode_value([1, 2], %{type: Ash.Type.Array}) == ["1", "2"]
      assert Types.encode_value([1, 2], %{type: :list}) == ["1", "2"]
      # Typed arrays keep native element values so the client emits e.g.
      # Array(Int64) rows as JSON numbers rather than strings.
      assert Types.encode_value([1, 2], %{type: {:array, :integer}}) == [1, 2]
    end

    test "encodes module Time type and time_usec, leaving non-Time values alone" do
      {:ok, time} = Time.from_iso8601("12:00:00")
      assert Types.encode_value(time, %{type: Ash.Type.Time}) == "12:00:00"
      assert Types.encode_value(time, %{type: :time_usec}) == "12:00:00"
      assert Types.encode_value(:not_a_time, %{type: :time_usec}) == :not_a_time
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

    test "decodes integer from a string with trailing junk, and non-numbers pass through" do
      assert Types.decode_value("99px", %{type: :integer}) == 99
      assert Types.decode_value("abc", %{type: :integer}) == "abc"
      assert Types.decode_value(1.5, %{type: :integer}) == 1.5
    end

    test "decodes float from string, int and float" do
      assert Types.decode_value("1.5", %{type: :float}) == 1.5
      assert Types.decode_value(2, %{type: :float}) == 2.0
      assert Types.decode_value(3.5, %{type: :float}) == 3.5
    end

    test "decodes float from a string with trailing junk, nil, and non-numbers pass through" do
      assert Types.decode_value("1.5em", %{type: :float}) == 1.5
      assert Types.decode_value("oops", %{type: :float}) == "oops"
      assert Types.decode_value(nil, %{type: :float}) == nil
      assert Types.decode_value(:no, %{type: :float}) == :no
    end

    test "decodes boolean from int, string and atom" do
      assert Types.decode_value(1, %{type: :boolean}) == true
      assert Types.decode_value(0, %{type: :boolean}) == false
      assert Types.decode_value("TRUE", %{type: :boolean}) == true
      assert Types.decode_value("0", %{type: :boolean}) == false
      assert Types.decode_value(true, %{type: :boolean}) == true
      assert Types.decode_value(false, %{type: :boolean}) == false
    end

    test "decodes boolean from 1/0 strings, nil, and passes non-matching values through" do
      assert Types.decode_value("1", %{type: :boolean}) == true
      assert Types.decode_value("false", %{type: :boolean}) == false
      assert Types.decode_value(nil, %{type: :boolean}) == nil
      assert Types.decode_value(:weird, %{type: :boolean}) == :weird
    end

    test "decodes decimal from string and Decimal" do
      assert %Decimal{} = Types.decode_value("2.5", %{type: :decimal})

      dec = %Decimal{coef: 25, exp: -1}
      assert Types.decode_value(dec, %{type: :decimal}) == dec
      assert Types.decode_value(nil, %{type: :decimal}) == nil
    end

    test "decodes decimal from a string with trailing junk, and non-numbers pass through" do
      assert %Decimal{} = Types.decode_value("2.5m", %{type: :decimal})
      assert Types.decode_value("abc", %{type: :decimal}) == "abc"
      assert Types.decode_value(42, %{type: :decimal}) == 42
    end

    test "decodes time from string" do
      {:ok, time} = Time.from_iso8601("01:02:03")
      assert Types.decode_value("01:02:03", %{type: :time}) == time
      assert Types.decode_value(nil, %{type: :time}) == nil
      assert Types.decode_value("garbage", %{type: :time}) == "garbage"
    end

    test "decodes non-string non-nil time values unchanged" do
      assert Types.decode_value(123, %{type: :time}) == 123
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
      uuid = "ffffffff-ffff-ffff-ffff-ffffffffffff"
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

    test "rejects invalid hex digits and wrong dash splits" do
      assert :error = Types.uuid_string_to_binary("123e4567-e89b-12d3-a456-42661417400g")
      assert :error = Types.uuid_string_to_binary("12345678-1234-1234-1234-12345678-extra")
    end

    test "uuid_like_string? is precise" do
      assert Types.uuid_like_string?("ffffffff-ffff-ffff-ffff-ffffffffffff")
      # `:mixed` case decoding accepts uppercase hex too.
      assert Types.uuid_like_string?("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
      refute Types.uuid_like_string?("ffffffff-ffff-ffff-ffff")
      refute Types.uuid_like_string?("zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz")
      refute Types.uuid_like_string?(123)
    end

    test "uuid_like_string? rejects wrong segment lengths" do
      refute Types.uuid_like_string?("12345678-1234-1234-1234-1234567890")
    end

    test "convert_uuid_param converts a 16-byte binary in a uuid column" do
      uuid = "123e4567-e89b-12d3-a456-426614174000"
      {:ok, bin} = Types.uuid_string_to_binary(uuid)
      uuid_fields = MapSet.new([:external_id, "external_id"])

      assert Types.convert_uuid_param(bin, :external_id, uuid_fields) == uuid
    end
  end

  describe "uuid_attribute_names/1 and atom_attribute_names/1" do
    defmodule UuidAttrResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      attributes do
        uuid_primary_key(:id)
        attribute(:external_id, :uuid)
        attribute(:status, :atom)
      end
    end

    test "recognizes atom-typed :uuid attributes" do
      names = Types.uuid_attribute_names(UuidAttrResource)
      assert :external_id in names
      assert "external_id" in names
      assert :id in names
    end

    test "recognizes atom-typed :atom attributes" do
      names = Types.atom_attribute_names(UuidAttrResource)
      assert :status in names
    end
  end
end
