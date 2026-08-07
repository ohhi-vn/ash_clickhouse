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

  test "implements Spark.Dsl.Extension so the Ash tasks discover it" do
    assert Spark.implements_behaviour?(Extension, Spark.Dsl.Extension)
  end

  test "name/0 returns a human-friendly label" do
    assert Extension.name() == "AshClickhouse"
  end

  test "codegen prints the CREATE TABLE DDL for a resource without applying it" do
    defmodule CodegenResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("codegen_table")
        repo(AshClickhouse.TestRepo)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string)
      end
    end

    output =
      capture_io(fn ->
        assert Extension.codegen(["--dry-run"], [CodegenResource]) == :ok
      end)

    create = Migration.create_table_cql(CodegenResource)
    assert output =~ create
    assert output =~ "CREATE TABLE IF NOT EXISTS"
  end

  test "codegen with --check raises when there are pending changes" do
    defmodule CheckResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("check_resource")
        repo(AshClickhouse.TestRepo)
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    assert_raise Mix.Error, fn -> Extension.codegen(["--check"], [CheckResource]) end

    defmodule CheckResourceMuted do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("check_resource_muted")
        repo(AshClickhouse.TestRepo)
        migrate(false)
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    assert Extension.codegen(["--check"], [CheckResourceMuted]) == :ok
  end
end
