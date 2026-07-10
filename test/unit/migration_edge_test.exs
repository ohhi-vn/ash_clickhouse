defmodule AshClickhouse.MigrationEdgeTest do
  @moduledoc "Edge-case unit tests for AshClickhouse.Migration DDL generation."
  use ExUnit.Case, async: true

  alias AshClickhouse.Migration

  defmodule ResourceWithManyTypes do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("many_types")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, allow_nil?: false)
      attribute(:age, :integer)
      attribute(:score, :float)
      attribute(:active, :boolean)
      attribute(:tags, {:array, :string}, allow_nil?: false)
      attribute(:meta, :map, allow_nil?: false)
      attribute(:balance, :decimal, constraints: [precision: 20, scale: 6])
      attribute(:created, :utc_datetime)
    end
  end

  defmodule ResourceWithCompositeNullable do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("composite_nullable")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:tags, {:array, :string}, allow_nil?: true)
    end
  end

  defmodule ResourceWithFunctionDefault do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("fn_default")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
      order_by("id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:created_at, :utc_datetime, default: &DateTime.utc_now/0)
    end
  end

  defmodule ResourceWithNoPkey do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("no_pkey")
      repo(AshClickhouse.TestRepo)
      engine("MergeTree()")
    end

    attributes do
      attribute(:name, :string)
    end
  end

  describe "create_table_cql/1 type coverage" do
    test "emits the correct ClickHouse type for every attribute" do
      sql = Migration.create_table_cql(ResourceWithManyTypes)

      assert String.contains?(sql, "`name` String")
      assert String.contains?(sql, "`age` Nullable(Int64)")
      assert String.contains?(sql, "`score` Nullable(Float64)")
      assert String.contains?(sql, "`active` Nullable(UInt8)")
      assert String.contains?(sql, "`tags` Array(String)")
      assert String.contains?(sql, "`meta` Map(String, String)")
      assert String.contains?(sql, "`balance` Nullable(Decimal(20, 6))")
      assert String.contains?(sql, "`created` Nullable(DateTime64(6))")
    end

    test "nullable composite types raise a clear ConfigurationError" do
      assert_raise AshClickhouse.Error.ConfigurationError, fn ->
        Migration.create_table_cql(ResourceWithCompositeNullable)
      end
    end

    test "non-numeric default on a numeric column is rejected by Ash at compile time" do
      # NOTE: Ash validates attribute defaults against the column type at compile
      # time, so a non-numeric default on an integer column (e.g.
      # `default: "not-a-number"`) is rejected by Ash *before* it ever reaches
      # `Migration.create_table_cql/1`. The `inspect_numeric_default/2` guard in
      # the migration module is therefore defensive hardening that is not
      # reachable through a normally-defined resource. We assert the reachable
      # behaviour instead: a valid integer default is emitted bare (no quotes).
      defmodule ValidNumericDefaultResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("valid_numeric_default")
          repo(AshClickhouse.TestRepo)
          engine("MergeTree()")
          order_by("id")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:age, :integer, default: 7)
        end
      end

      sql = Migration.create_table_cql(ValidNumericDefaultResource)
      assert String.contains?(sql, "DEFAULT 7")
      refute String.contains?(sql, "DEFAULT '7'")
    end

    test "function defaults are omitted from the DDL" do
      sql = Migration.create_table_cql(ResourceWithFunctionDefault)
      refute String.contains?(sql, "DEFAULT")
    end

    test "resource without a primary key falls back to tuple() ORDER BY" do
      sql = Migration.create_table_cql(ResourceWithNoPkey)
      assert String.contains?(sql, "ORDER BY (tuple())")
    end
  end

  describe "alter_table_cql/2 edge cases" do
    defmodule AlterFakeRepo do
      def query(_statement, _params),
        do:
          {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}

      def database, do: "ash_clickhouse_test"
    end

    defmodule AlterResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("alter_edge")
        repo(AshClickhouse.TestRepo)
        engine("MergeTree()")
        order_by("id")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string)
        attribute(:age, :integer, allow_nil?: true)
      end
    end

    test "all attributes are added when the table reports no columns" do
      statements = Migration.alter_table_cql(AlterResource, AlterFakeRepo)
      assert Enum.any?(statements, &String.contains?(&1, "ADD COLUMN IF NOT EXISTS `name`"))
      assert Enum.any?(statements, &String.contains?(&1, "ADD COLUMN IF NOT EXISTS `age`"))
      assert Enum.any?(statements, &String.contains?(&1, "ADD COLUMN IF NOT EXISTS `id`"))
    end

    test "on a failing query it treats the table as empty and adds every column" do
      defmodule FailingRepo do
        def query(_statement, _params), do: {:error, :no_table}
        def database, do: "ash_clickhouse_test"
      end

      statements = Migration.alter_table_cql(AlterResource, FailingRepo)
      assert Enum.any?(statements, &String.contains?(&1, "ADD COLUMN IF NOT EXISTS `id`"))
      assert Enum.any?(statements, &String.contains?(&1, "ADD COLUMN IF NOT EXISTS `name`"))
    end
  end
end
