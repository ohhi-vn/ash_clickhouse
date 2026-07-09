defmodule AshClickhouse.MigrationTest do
  @moduledoc "Unit tests for AshClickhouse.Migration SQL generation."
  use ExUnit.Case, async: true

  alias AshClickhouse.Migration

  describe "create_table_cql/1" do
    test "generates a CREATE TABLE statement for the test resource" do
      sql = Migration.create_table_cql(AshClickhouse.TestResource)

      assert String.starts_with?(sql, "CREATE TABLE IF NOT EXISTS `ash_clickhouse_test`.`test_users`")
      assert String.contains?(sql, "ENGINE = MergeTree()")
      assert String.contains?(sql, "ORDER BY")
      assert String.contains?(sql, "`id` UUID")
      assert String.contains?(sql, "`name` Nullable(String)")
      assert String.contains?(sql, "`age` Nullable(Int64)")
    end

    test "wraps nullable attributes in Nullable(...) rather than trailing NULL" do
      defmodule ResourceWithNullable do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("nullable_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: true)
          attribute(:age, :integer, allow_nil?: false)
        end
      end

      sql = Migration.create_table_cql(ResourceWithNullable)
      assert String.contains?(sql, "`name` Nullable(String)")
      assert String.contains?(sql, "`age` Int64")
      refute String.contains?(sql, "NULL")
      refute String.contains?(sql, "NOT NULL")
    end

    test "rejects allow_nil? on composite (Array/Map) attributes" do
      defmodule ResourceWithNullableArray do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("nullable_array_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:tags, {:array, :string}, allow_nil?: true)
        end
      end

      assert_raise AshClickhouse.Error.ConfigurationError, fn ->
        Migration.create_table_cql(ResourceWithNullableArray)
      end
    end

    test "escapes embedded quotes/backslashes in String/UUID defaults" do
      defmodule ResourceWithDefault do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("default_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:label, :string, default: "O'Brien\\escaped")
        end
      end

      sql = Migration.create_table_cql(ResourceWithDefault)
      assert String.contains?(sql, "DEFAULT 'O\\'Brien\\\\escaped'")
    end
  end

  describe "generate_resource_cql/1" do
    test "returns a list with a single CREATE TABLE statement" do
      [sql] = Migration.generate_resource_cql(AshClickhouse.TestResource)
      assert String.starts_with?(sql, "CREATE TABLE IF NOT EXISTS")
    end
  end

  describe "alter_table_cql/2" do
    defmodule FakeRepo do
      def query(_statement, _params),
        do: {
          :ok,
          %ClickHouse.Result{
            raw: "",
            meta: %{},
            compressed: false,
            rows: [["id"]],
            columns: ["name"]
          }
        }

      def database, do: "ash_clickhouse_test"
    end

    test "emits ADD COLUMN IF NOT EXISTS for attributes missing from the table" do
      defmodule ResourceForAlter do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("alter_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
          attribute(:age, :integer, allow_nil?: true)
        end
      end

      # FakeRepo reports only `id` exists, so `name` and `age` should be added.
      statements = Migration.alter_table_cql(ResourceForAlter, FakeRepo)

      assert Enum.any?(
               statements,
               &String.contains?(&1, "ADD COLUMN IF NOT EXISTS `name` Nullable(String)")
             )

      assert Enum.any?(
               statements,
               &String.contains?(&1, "ADD COLUMN IF NOT EXISTS `age` Nullable(Int64)")
             )

      refute Enum.any?(statements, &String.contains?(&1, "`id`"))
    end

    test "returns no statements when all attributes already exist" do
      defmodule ResourceFullyPresent do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("present_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      defmodule FullyPresentRepo do
        def query(_statement, _params),
          do: {
            :ok,
            %ClickHouse.Result{
              raw: "",
              meta: %{},
              compressed: false,
              rows: [["id"], ["name"]],
              columns: ["name"]
            }
          }

        def database, do: "ash_clickhouse_test"
      end

      statements = Migration.alter_table_cql(ResourceFullyPresent, FullyPresentRepo)
      assert statements == []
    end
  end
end
