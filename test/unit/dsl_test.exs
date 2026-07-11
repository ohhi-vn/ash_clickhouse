defmodule AshClickhouse.DslTest do
  @moduledoc "Unit tests for AshClickhouse.DataLayer.Dsl configuration parsing."
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.Dsl

  defmodule ResourceWithFullConfig do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("full_table")
      repo(AshClickhouse.TestRepo)
      database("full_db")
      engine("ReplacingMergeTree()")
      order_by("created_at")
      partition_by("toYYYYMM(created_at)")
      primary_key([:id])
      settings("index_granularity = 8192")
      base_filter(status: "active")
      default_context(%{tenant: "org_1"})
      description("a full config")
      migrate(false)
      insert_opts(async_insert: 1, wait_for_async_insert: 1)
      mutations_sync(1)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:status, :string)
    end
  end

  describe "config getters" do
    test "read every configured value back" do
      assert Dsl.table(ResourceWithFullConfig) == "full_table"
      assert Dsl.repo(ResourceWithFullConfig) == AshClickhouse.TestRepo
      assert Dsl.database(ResourceWithFullConfig) == "full_db"
      assert Dsl.engine(ResourceWithFullConfig) == "ReplacingMergeTree()"
      assert Dsl.order_by(ResourceWithFullConfig) == "created_at"
      assert Dsl.partition_by(ResourceWithFullConfig) == "toYYYYMM(created_at)"
      assert Dsl.primary_key(ResourceWithFullConfig) == [:id]
      assert Dsl.settings(ResourceWithFullConfig) == "index_granularity = 8192"
      assert Dsl.base_filter(ResourceWithFullConfig) == [status: "active"]
      assert Dsl.default_context(ResourceWithFullConfig) == %{tenant: "org_1"}
      assert Dsl.description(ResourceWithFullConfig) == "a full config"
      refute Dsl.migrate?(ResourceWithFullConfig)

      assert Dsl.insert_opts(ResourceWithFullConfig) == [
               async_insert: 1,
               wait_for_async_insert: 1
             ]

      assert Dsl.mutations_sync(ResourceWithFullConfig) == 1
    end

    test "defaults when nothing is configured" do
      defmodule MinimalResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("minimal")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      assert Dsl.engine(MinimalResource) == "MergeTree()"
      assert Dsl.migrate?(MinimalResource)
      assert Dsl.database(MinimalResource) == nil
      assert Dsl.order_by(MinimalResource) == nil
      assert Dsl.insert_opts(MinimalResource) == []
      assert Dsl.mutations_sync(MinimalResource) == nil
    end
  end

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

  describe "index DSL" do
    test "indexes are accumulated and read back via Dsl.indexes/1" do
      indexes = Dsl.indexes(ResourceWithIndexes)
      assert length(indexes) == 2

      assert Enum.find(indexes, fn idx -> idx.name == :idx_user_id end) == %{
               name: :idx_user_id,
               expression: "user_id",
               type: "bloom_filter",
               granularity: 1
             }

      assert Enum.find(indexes, fn idx -> idx.name == :idx_created_at end) == %{
               name: :idx_created_at,
               expression: "created_at",
               type: "minmax",
               granularity: 4
             }
    end

    test "a resource without indexes returns an empty list" do
      assert Dsl.indexes(ResourceWithFullConfig) == []
    end
  end

  describe "top-level-only DSL walk" do
    test "a nested call shaped like a DSL key inside a value is not rewritten" do
      # `partition_by` receives an expression that itself contains a call named
      # `table` (a helper macro imported into the module). Because the DSL only
      # rewrites top-level statements, the inner `table(...)` must NOT be
      # misinterpreted as the `table` DSL setter.
      defmodule TableHelper do
        defmacro table(_), do: "ignored"
      end

      defmodule ResourceWithNestedHelper do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros
        import TableHelper

        clickhouse do
          repo(AshClickhouse.TestRepo)
          table("nested_table")
          partition_by(table(:something))
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      assert Dsl.table(ResourceWithNestedHelper) == "nested_table"
      # The inner `table(:something)` must NOT be rewritten into a table setter,
      # so `partition_by` keeps the helper's expanded value verbatim.
      assert Dsl.partition_by(ResourceWithNestedHelper) == "ignored"
    end
  end
end
