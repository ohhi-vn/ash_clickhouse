defmodule AshClickhouse.MigrationDefaultsTest do
  @moduledoc "Unit tests for Migration default literals, database-qualified DDL, and index mismatch warnings."
  use ExUnit.Case, async: true

  alias AshClickhouse.Migration

  defmodule DefaultsResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("defaults_table")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:external_id, :uuid, default: "123e4567-e89b-12d3-a456-426614174000")
      attribute(:ratio, :float, default: 1.5, allow_nil?: false)
      attribute(:day, :date, default: ~D[2024-01-02], allow_nil?: false)
      attribute(:created_at, :utc_datetime, default: ~U[2024-01-02 03:04:05Z], allow_nil?: false)
      attribute(:count, :integer, default: 42, allow_nil?: false)
    end
  end

  describe "default literal generation" do
    test "renders UUID, float, Date, DateTime, and integer defaults" do
      sql = Migration.create_table_cql(DefaultsResource)

      assert String.contains?(sql, "DEFAULT '123e4567-e89b-12d3-a456-426614174000'")
      assert String.contains?(sql, "DEFAULT 1.5")
      assert String.contains?(sql, "DEFAULT '2024-01-02'")
      assert String.contains?(sql, "DEFAULT '2024-01-02 03:04:05Z'")
      assert String.contains?(sql, "DEFAULT 42")
    end
  end

  describe "database-qualified ALTER statements" do
    defmodule DbIndexResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("db_table")
        repo(AshClickhouse.TestRepo)
        database("custom_db")
        order_by("id")

        index(name: :idx_a, expression: "a", type: "minmax")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:a, :string)
      end
    end

    defmodule ExistingColumnsRepo do
      def query(_statement, _params) do
        {:ok,
         %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [["id"]], columns: ["name"]}}
      end

      def database, do: "custom_db"
    end

    defmodule NoIndexRepo do
      def query(_statement, _params) do
        {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: ["name"]}}
      end

      def database, do: "custom_db"
    end

    defmodule FailingRepo do
      def query(_statement, _params), do: {:error, :boom}
      def database, do: "custom_db"
    end

    defmodule RaisingRepo do
      def query(_statement, _params), do: raise("connection lost")
      def database, do: "custom_db"
    end

    test "alter_table_cql/2 qualifies the table with the configured database" do
      [statement] = Migration.alter_table_cql(DbIndexResource, ExistingColumnsRepo)
      assert String.starts_with?(statement, "ALTER TABLE `custom_db`.`db_table`")
    end

    test "alter_indexes_cql/2 qualifies the table with the configured database" do
      {statements, warnings} = Migration.alter_indexes_cql(DbIndexResource, NoIndexRepo)
      assert warnings == []
      assert Enum.any?(statements, &String.starts_with?(&1, "ALTER TABLE `custom_db`.`db_table`"))
    end

    test "alter_indexes_cql/2 degrades to an empty index map on query error" do
      {statements, warnings} = Migration.alter_indexes_cql(DbIndexResource, FailingRepo)
      assert warnings == []
      assert length(statements) == 1
    end

    test "alter_indexes_cql/2 degrades to an empty index map when the lookup raises" do
      {statements, warnings} = Migration.alter_indexes_cql(DbIndexResource, RaisingRepo)
      assert warnings == []
      assert length(statements) == 1
    end
  end

  describe "index mismatch warnings" do
    defmodule MismatchIndexResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("mismatch_table")
        repo(AshClickhouse.TestRepo)
        order_by("id")

        index(name: :idx_a, expression: "a", type: "minmax")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:a, :string)
      end
    end

    defmodule BothMismatchRepo do
      def query(_statement, _params) do
        {:ok,
         %ClickHouse.Result{
           raw: "",
           meta: %{},
           compressed: false,
           rows: [["idx_a", "set", "completely_different"]],
           columns: ["name", "type", "expr"]
         }}
      end

      def database, do: "custom_db"
    end

    defmodule ExprOnlyMismatchRepo do
      def query(_statement, _params) do
        {:ok,
         %ClickHouse.Result{
           raw: "",
           meta: %{},
           compressed: false,
           rows: [["idx_a", "minmax", nil]],
           columns: ["name", "type", "expr"]
         }}
      end

      def database, do: "custom_db"
    end

    test "warns when both type and expression differ" do
      {statements, [warning]} = Migration.alter_indexes_cql(MismatchIndexResource, BothMismatchRepo)

      assert statements == []
      assert warning =~ "BOTH type and expression"
      assert warning =~ "DROP INDEX"
    end

    test "warns when only the expression differs (including nil stored expr)" do
      {statements, [warning]} =
        Migration.alter_indexes_cql(MismatchIndexResource, ExprOnlyMismatchRepo)

      assert statements == []
      assert warning =~ "has expression"
      assert warning =~ "DROP INDEX"
    end
  end
end
