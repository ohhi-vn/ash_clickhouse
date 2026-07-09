defmodule AshClickhouse.MigrationExtraTest do
  @moduledoc "Additional unit tests for AshClickhouse.Migration DDL generation."
  use ExUnit.Case, async: true

  alias AshClickhouse.Migration

  defmodule ResourceWithPartition do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("extra_table")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
      partition_by("toYYYYMM(created_date)")
      primary_key([:id])
      settings("index_granularity = 8192")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:created_date, :date)
    end
  end

  defmodule ResourceWithDefaultOrderBy do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("extra_table")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  defmodule ResourceWithCustomEngine do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("extra_table")
      repo(AshClickhouse.TestRepo)
      engine("ReplacingMergeTree()")
      order_by("id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  defmodule ResourceMinimal do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("extra_table")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  defmodule ResourceWithComposite do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("extra_table")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:tags, {:array, :string}, allow_nil?: false)
      attribute(:meta, :map, allow_nil?: false)
    end
  end

  defmodule ResourceWithDecimal do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("extra_table")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:score, :decimal, allow_nil?: false, constraints: [precision: 12, scale: 4])
    end
  end

  defmodule ResourceWithPartitionOnly do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("extra_table")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
      partition_by("toYYYYMM(toDate(now()))")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  describe "create_table_cql/1 with engine options" do
    test "emits PARTITION BY, PRIMARY KEY and SETTINGS clauses" do
      sql = Migration.create_table_cql(ResourceWithPartition)
      assert String.contains?(sql, "PARTITION BY toYYYYMM(created_date)")
      assert String.contains?(sql, "PRIMARY KEY (`id`)")
      assert String.contains?(sql, "SETTINGS index_granularity = 8192")
      assert String.contains?(sql, "ENGINE = MergeTree()")
    end

    test "defaults ORDER BY to the primary key when order_by is not set" do
      sql = Migration.create_table_cql(ResourceWithDefaultOrderBy)
      assert String.contains?(sql, "ORDER BY (`id`)")
    end

    test "supports a custom engine" do
      sql = Migration.create_table_cql(ResourceWithCustomEngine)
      assert String.contains?(sql, "ENGINE = ReplacingMergeTree()")
    end

    test "does not emit empty clauses for missing options" do
      sql = Migration.create_table_cql(ResourceMinimal)
      refute String.contains?(sql, "PARTITION BY")
      refute String.contains?(sql, "PRIMARY KEY")
      refute String.contains?(sql, "SETTINGS")
    end
  end

  describe "create_table_cql/1 with composite (non-nullable) types" do
    test "emits Array/String and Map types without Nullable wrapping" do
      sql = Migration.create_table_cql(ResourceWithComposite)
      assert String.contains?(sql, "`tags` Array(String)")
      assert String.contains?(sql, "`meta` Map(String, String)")
      refute String.contains?(sql, "Nullable(Array")
      refute String.contains?(sql, "Nullable(Map")
    end

    test "maps decimal attributes to Decimal(...) with constraints" do
      sql = Migration.create_table_cql(ResourceWithDecimal)
      assert String.contains?(sql, "`score` Decimal(12, 4)")
    end
  end

  describe "generate_resource_cql/1" do
    test "returns a single CREATE TABLE statement for a partitioned resource" do
      [sql] = Migration.generate_resource_cql(ResourceWithPartitionOnly)
      assert String.starts_with?(sql, "CREATE TABLE IF NOT EXISTS")
      assert String.contains?(sql, "PARTITION BY")
    end
  end
end
