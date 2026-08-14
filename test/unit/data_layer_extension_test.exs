defmodule AshClickhouse.DataLayer.ExtensionTest do
  @moduledoc """
  Tests that `AshClickhouse.DataLayer.Extension` integrates with the standard
  Ash mix tasks (`mix ash.codegen` / `mix ash.migrate`) via `codegen/1` and
  `migrate/1`.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias AshClickhouse.DataLayer.Extension
  alias AshClickhouse.Migration

  defmodule FakeRepo do
    def query(statement, _params) do
      send(self(), {:repo_query, statement})
      {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}
    end

    def database, do: "test_db"
  end

  defmodule FakeRepo2 do
    def query(_statement, _params),
      do: {:error, :connection_failed}

    def database, do: "test_db"
  end

  defmodule AlterRepo do
    def query("SELECT 1 FROM system.tables" <> _, _params), do: {:ok, result([[1]])}
    def query("SELECT name FROM system.columns" <> _, _params), do: {:ok, result([["id"]])}
    def query(_statement, _params), do: {:ok, result([])}

    def database, do: "test_db"

    defp result(rows) do
      %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: rows, columns: []}
    end
  end

  defmodule MigrateResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("migrate_table")
      repo(FakeRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  defmodule AlterResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("alter_table")
      repo(AlterRepo)

      index(name: :idx_name, expression: "name", type: "minmax")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  defmodule MutedResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("muted_table")
      repo(FakeRepo)
      migrate(false)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defmodule NoRepoResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("no_repo_table")
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defmodule OtherRepoResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("other_repo_table")
      repo(FakeRepo2)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defmodule ErrorResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("error_table")
      repo(FakeRepo2)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defp capture_all(fun) do
    out =
      capture_io(fn ->
        err = capture_io(:stderr, fun)
        Process.put(:captured_err, err)
      end)

    out <> Process.get(:captured_err, "")
  end

  test "implements Spark.Dsl.Extension so the Ash tasks discover it" do
    assert Spark.implements_behaviour?(Extension, Spark.Dsl.Extension)
  end

  test "name/0 returns a human-friendly label" do
    assert Extension.name() == "AshClickhouse"
  end

  describe "codegen/2" do
    test "prints the CREATE TABLE DDL for a resource without applying it" do
      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], [MigrateResource]) == :ok
        end)

      create = Migration.create_table_cql(MigrateResource)
      assert output =~ create
      assert output =~ "CREATE TABLE IF NOT EXISTS"
    end

    test "prints ALTER statements for missing columns and indexes" do
      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], [AlterResource]) == :ok
        end)

      assert output =~ "ALTER TABLE `alter_table` ADD COLUMN IF NOT EXISTS `name`"
      assert output =~ "ALTER TABLE `alter_table` ADD INDEX IF NOT EXISTS `idx_name`"
    end

    test "prints nothing pending and reports when there are no changes" do
      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], []) == :ok
        end)

      assert output =~ "No pending ClickHouse changes."
    end

    test "with --check raises when there are pending changes" do
      assert_raise Mix.Error, fn -> Extension.codegen(["--check"], [MigrateResource]) end
    end

    test "with --check passes when a resource has migrate disabled" do
      assert Extension.codegen(["--check"], [MutedResource]) == :ok
    end

    test "skips resources with migrate disabled" do
      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], [MutedResource]) == :ok
        end)

      assert output =~ "No pending ClickHouse changes."
      refute output =~ "CREATE TABLE IF NOT EXISTS"
    end

    test "does not crash on a resource without a repo configured" do
      output =
        capture_all(fn ->
          assert Extension.codegen(["--dry-run"], [NoRepoResource]) == :ok
        end)

      assert output =~ "no repo configured"
      refute output =~ "CREATE TABLE IF NOT EXISTS"
    end
  end

  describe "migrate/2" do
    test "applies CREATE / ALTER statements via the resource's repo" do
      output =
        capture_io(fn ->
          assert Extension.migrate([FakeRepo], [MigrateResource]) == :ok
        end)

      assert output =~ "Migrated AshClickhouse.DataLayer.ExtensionTest.MigrateResource"
      assert output =~ "Altered AshClickhouse.DataLayer.ExtensionTest.MigrateResource"
    end

    test "skips resources whose repo is not in the list" do
      output =
        capture_all(fn ->
          assert Extension.migrate([FakeRepo], [OtherRepoResource]) == :ok
        end)

      refute output =~ "Migrated"
      refute output =~ "connection_failed"
    end

    test "skips resources with migrate disabled" do
      output =
        capture_all(fn ->
          assert Extension.migrate([FakeRepo], [MutedResource]) == :ok
        end)

      refute output =~ "Migrated"
    end

    test "reports resources without a repo configured" do
      output =
        capture_all(fn ->
          assert Extension.migrate([FakeRepo], [NoRepoResource]) == :ok
        end)

      assert output =~ "no repo configured"
      refute output =~ "Migrated"
    end

    test "reports repo query failures without raising" do
      output =
        capture_all(fn ->
          assert Extension.migrate([FakeRepo2], [ErrorResource]) == :ok
        end)

      assert output =~ "Failed to migrate"
      refute output =~ "Migrated"
    end

    test "returns :ok with empty repos and resources" do
      assert Extension.migrate([], []) == :ok
    end
  end
end
