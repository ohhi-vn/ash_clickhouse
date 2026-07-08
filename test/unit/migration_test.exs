defmodule AshClickhouse.MigrationTest do
  @moduledoc "Unit tests for AshClickhouse.Migration SQL generation."
  use ExUnit.Case, async: true

  alias AshClickhouse.Migration

  describe "create_table_cql/1" do
    test "generates a CREATE TABLE statement for the test resource" do
      sql = Migration.create_table_cql(AshClickhouse.TestResource)

      assert String.starts_with?(sql, "CREATE TABLE IF NOT EXISTS `test_users`")
      assert String.contains?(sql, "ENGINE = MergeTree()")
      assert String.contains?(sql, "ORDER BY")
      assert String.contains?(sql, "`id` UUID")
      assert String.contains?(sql, "`name` String")
      assert String.contains?(sql, "`age` Int64")
    end

    test "includes a primary key clause when configured" do
      defmodule ResourceWithPk do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer

        import AshClickhouse.DataLayer.Dsl

        clickhouse do
          table "pk_table"
          repo AshClickhouse.TestRepo
          primary_key [:id]
        end

        attributes do
          uuid_primary_key :id
        end
      end

      sql = Migration.create_table_cql(ResourceWithPk)
      assert String.contains?(sql, "PRIMARY KEY (`id`)")
    end
  end

  describe "generate_resource_cql/1" do
    test "returns a list with a single CREATE TABLE statement" do
      [sql] = Migration.generate_resource_cql(AshClickhouse.TestResource)
      assert String.starts_with?(sql, "CREATE TABLE IF NOT EXISTS")
    end
  end
end
