defmodule AshClickhouseTest do
  use ExUnit.Case
  doctest AshClickhouse

  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.DataLayer.Types
  alias AshClickhouse.Identifier

  describe "version" do
    test "returns a string" do
      assert is_binary(AshClickhouse.version())
    end
  end

  describe "AshClickhouse.Identifier" do
    test "quote_name quotes and escapes backticks" do
      assert Identifier.quote_name("users") == "`users`"
      assert Identifier.quote_name("my`table") == "`my``table`"
    end

    test "sanitize! accepts valid identifiers and rejects invalid ones" do
      assert Identifier.sanitize!("valid_name") == "valid_name"

      assert_raise ArgumentError, fn ->
        Identifier.sanitize!("1invalid")
      end

      assert_raise ArgumentError, fn ->
        Identifier.sanitize!("invalid-name")
      end
    end
  end

  describe "AshClickhouse.DataLayer.Types" do
    test "maps Ash types to ClickHouse types" do
      assert Types.ash_type_to_clickhouse(:uuid) == "UUID"
      assert Types.ash_type_to_clickhouse(:integer) == "Int64"
      assert Types.ash_type_to_clickhouse(:string) == "String"
      assert Types.ash_type_to_clickhouse(:boolean) == "UInt8"
      assert Types.ash_type_to_clickhouse(:float) == "Float64"
      assert Types.ash_type_to_clickhouse(:date) == "Date"
    end

    test "uuid string <-> binary round trip" do
      uuid = "550E8400-E29B-41D4-A716-446655440000"
      {:ok, bin} = Types.uuid_string_to_binary(uuid)
      assert byte_size(bin) == 16
      {:ok, back} = Types.uuid_binary_to_string(bin)
      assert back == uuid
    end
  end

  describe "AshClickhouse.DataLayer.QueryBuilder" do
    test "builds a basic SELECT" do
      query = %AshClickhouse.Query{
        table: "users",
        database: nil,
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        distinct: nil
      }

      {sql, params} = QueryBuilder.build_optimized_query(query)
      assert sql == "SELECT * FROM `users`"
      assert params == []
    end

    test "builds WHERE, ORDER BY, LIMIT, OFFSET" do
      filter = %{
        operator: :eq,
        left: %{name: :status},
        right: %{value: "active"}
      }

      query = %AshClickhouse.Query{
        table: "users",
        database: "app",
        filters: [filter],
        sorts: [{:name, :asc}],
        limit: 10,
        offset: 5,
        select: [:id, :name]
      }

      {sql, params} =
        QueryBuilder.build_optimized_query(query)

      assert sql ==
               "SELECT `id`, `name` FROM `app`.`users` WHERE `status` = ? ORDER BY `name` ASC LIMIT 10 OFFSET 5"

      assert params == ["active"]
    end
  end

  describe "AshClickhouse.DataLayer feature support" do
    test "reports supported and unsupported features" do
      assert AshClickhouse.DataLayer.can?(nil, :create)
      assert AshClickhouse.DataLayer.can?(nil, :offset)
      refute AshClickhouse.DataLayer.can?(nil, :transact)
      refute AshClickhouse.DataLayer.can?(nil, :keyset)
      refute AshClickhouse.DataLayer.can?(nil, :upsert)
      refute AshClickhouse.DataLayer.can?(nil, :join)
      refute AshClickhouse.DataLayer.can?(nil, :combine)
    end
  end
end
