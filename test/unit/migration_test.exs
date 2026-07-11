defmodule AshClickhouse.MigrationTest do
  @moduledoc "Unit tests for AshClickhouse.Migration SQL generation."
  use ExUnit.Case, async: true

  alias AshClickhouse.Migration

  describe "create_table_cql/1" do
    test "generates a CREATE TABLE statement for the test resource" do
      sql = Migration.create_table_cql(AshClickhouse.TestResource)

      assert String.starts_with?(
               sql,
               "CREATE TABLE IF NOT EXISTS `ash_clickhouse_test`.`test_users`"
             )

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

  describe "index CQL generation" do
    defmodule ResourceWithIndexes do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("indexed_table")
        repo(AshClickhouse.TestRepo)
        order_by("id")

        index(name: :idx_user_id, expression: "user_id", type: "bloom_filter")
        index(name: :idx_created_at, expression: "created_at", type: "minmax", granularity: 4)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:user_id, :string)
        attribute(:created_at, :utc_datetime)
      end
    end

    test "create_table_cql/1 emits index definitions" do
      sql = Migration.create_table_cql(ResourceWithIndexes)

      assert String.contains?(
               sql,
               "INDEX `idx_user_id` (user_id) TYPE bloom_filter GRANULARITY 1"
             )

      assert String.contains?(
               sql,
               "INDEX `idx_created_at` (created_at) TYPE minmax GRANULARITY 4"
             )
    end

    test "create_table_cql/1 omits indexes for a resource without any" do
      sql = Migration.create_table_cql(AshClickhouse.TestResource)
      refute String.contains?(sql, "INDEX ")
    end
  end

  describe "alter_indexes_cql/2" do
    defmodule IndexResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("index_resource")
        repo(AshClickhouse.TestRepo)
        order_by("id")

        index(name: :idx_a, expression: "a", type: "minmax")
        index(name: :idx_b, expression: "b", type: "bloom_filter", granularity: 2)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:a, :string)
        attribute(:b, :string)
      end
    end

    defmodule NoIndexRepo do
      def query(_statement, _params),
        do:
          {:ok,
           %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: ["name"]}}

      def database, do: "ash_clickhouse_test"
    end

    defmodule PartialIndexRepo do
      # Reports that `idx_a` already exists (matching the config), so only
      # `idx_b` should be added and no warning should be emitted for `idx_a`.
      def query(_statement, _params),
        do: {
          :ok,
          %ClickHouse.Result{
            raw: "",
            meta: %{},
            compressed: false,
            rows: [["idx_a", "minmax", "a"]],
            columns: ["name", "type", "expr"]
          }
        }

      def database, do: "ash_clickhouse_test"
    end

    defmodule MismatchRepo do
      # `idx_a` exists but with a different type than configured -> warning.
      # `idx_b` exists and matches -> no warning, not added.
      def query(_statement, _params),
        do: {
          :ok,
          %ClickHouse.Result{
            raw: "",
            meta: %{},
            compressed: false,
            rows: [["idx_a", "set", "a"], ["idx_b", "bloom_filter", "b"]],
            columns: ["name", "type", "expr"]
          }
        }

      def database, do: "ash_clickhouse_test"
    end

    test "proposes ADD INDEX for every configured index when none exist" do
      {statements, warnings} = Migration.alter_indexes_cql(IndexResource, NoIndexRepo)
      assert length(statements) == 2
      assert warnings == []

      assert Enum.any?(
               statements,
               &String.contains?(
                 &1,
                 "ADD INDEX IF NOT EXISTS INDEX `idx_a` (a) TYPE minmax GRANULARITY 1"
               )
             )

      assert Enum.any?(
               statements,
               &String.contains?(
                 &1,
                 "ADD INDEX IF NOT EXISTS INDEX `idx_b` (b) TYPE bloom_filter GRANULARITY 2"
               )
             )
    end

    test "skips indexes that already exist (and match) in ClickHouse" do
      {statements, warnings} = Migration.alter_indexes_cql(IndexResource, PartialIndexRepo)
      assert length(statements) == 1
      assert warnings == []
      assert Enum.any?(statements, &String.contains?(&1, "`idx_b`"))
      refute Enum.any?(statements, &String.contains?(&1, "`idx_a`"))
    end

    test "warns (but does not auto-correct) when an existing index's type differs" do
      {statements, warnings} = Migration.alter_indexes_cql(IndexResource, MismatchRepo)
      # idx_a mismatches (type set vs minmax) -> warning, not added.
      # idx_b matches -> no statement, no warning.
      assert statements == []
      assert length(warnings) == 1
      assert Enum.any?(warnings, &String.contains?(&1, "idx_a"))
      assert Enum.any?(warnings, &String.contains?(&1, "DROP INDEX"))
      assert Enum.any?(warnings, &String.contains?(&1, "ADD INDEX"))
    end

    test "returns empty {[], []} when the resource has no indexes" do
      assert Migration.alter_indexes_cql(AshClickhouse.TestResource, NoIndexRepo) == {[], []}
    end

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
