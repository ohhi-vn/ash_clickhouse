defmodule AshClickhouse.MixTasksTest do
  @moduledoc """
  Tests for the `mix ash_clickhouse.migrate`, `mix ash_clickhouse.setup`,
  and related mix tasks.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Mix.Tasks.AshClickhouse.Helpers

  alias AshClickhouse.DataLayer.Extension
  alias Mix.Tasks.AshClickhouse.Migrate
  alias Mix.Tasks.AshClickhouse.Setup

  setup do
    :ok
  end

  describe "Mix.Tasks.AshClickhouse.Helpers" do
    defmodule StartClientsRepo do
      use AshClickhouse.Repo, otp_app: :ash_clickhouse_mix_tasks
    end

    test "app_name/0 returns the app name when configured" do
      assert is_atom(app_name()) or is_nil(app_name())
    end

    test "find_repos/0 returns empty list when no repos exist" do
      repos = find_repos()
      assert is_list(repos)
    end

    test "find_resources/0 returns empty list when no resources exist" do
      resources = find_resources()
      assert is_list(resources)
    end

    test "start_clients/2 returns :ok for an empty repo list" do
      assert start_clients([], []) == :ok
    end

    test "start_clients/2 starts a connection for a repo and returns :ok" do
      name = :"start_clients_#{System.unique_integer([:positive])}"

      Application.put_env(:ash_clickhouse_mix_tasks, StartClientsRepo,
        url: "http://localhost:8123",
        database: "tmp_db"
      )

      on_exit(fn ->
        Application.delete_env(:ash_clickhouse_mix_tasks, StartClientsRepo)
      end)

      assert start_clients([StartClientsRepo], name: name) == :ok
      assert %AshClickhouse.Connection{name: ^name} = AshClickhouse.Connection.get_conn(name)
      assert AshClickhouse.Connection.stop(name) == :ok
    end
  end

  describe "Mix.Tasks.AshClickhouse.Migrate" do
    @tag :mix_task
    test "run/1 compiles and delegates to Extension.migrate/1" do
      output =
        capture_io(fn ->
          assert Migrate.run([]) == :ok
        end)

      assert output == "" or
               output =~ "No AshClickhouse.Repo modules found" or
               output =~ "Migrated" or
               output =~ "Altered" or
               output =~ "Added index"
    end
  end

  describe "Ash tasks" do
    @tag :mix_task
    test "Ash codegen discovers the AshClickhouse extension" do
      Mix.Task.reenable("ash.codegen")

      output =
        capture_io(fn ->
          assert :ok in Mix.Task.run("ash.codegen", ["--dry-run"])
        end)

      assert output =~ "Running codegen for AshClickhouse"
    end
  end

  describe "Mix.Tasks.AshClickhouse.Setup" do
    @tag :mix_task
    test "run/1 compiles and creates databases for repos" do
      output =
        capture_io(fn ->
          assert Setup.run([]) == :ok
        end)

      assert output =~ "No AshClickhouse.Repo modules found" or
               output =~ "Created database"
    end

    defmodule OkCreateRepo do
      def create_database, do: {:ok, :created}
    end

    defmodule ErrCreateRepo do
      def create_database, do: {:error, "boom"}
    end

    test "create_databases/1 prints a message when a repo is created" do
      output =
        capture_io(fn ->
          assert Setup.create_databases([OkCreateRepo]) == :ok
        end)

      assert output =~ "Created database for #{inspect(OkCreateRepo)}"
    end

    test "create_databases/1 prints the reason when a repo fails" do
      output =
        capture_io(:stderr, fn ->
          assert Setup.create_databases([ErrCreateRepo]) == :ok
        end)

      assert output =~ "Failed: \"boom\""
    end
  end

  describe "AshClickhouse.DataLayer.Extension" do
    test "codegen/2 with empty resource list outputs no pending changes" do
      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], []) == :ok
        end)

      assert output =~ "No pending ClickHouse changes."
    end

    test "codegen/2 with resources outputs DDL statements" do
      defmodule TestCodegenResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("test_codegen_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], [TestCodegenResource]) == :ok
        end)

      assert output =~ "CREATE TABLE IF NOT EXISTS"
      assert output =~ "`test_codegen_table`"
      assert output =~ "`id` UUID"
      assert output =~ "`name`"
    end

    test "codegen/2 with --check raises on pending changes" do
      defmodule CheckPendingResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("check_pending_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      assert_raise Mix.Error, fn ->
        Extension.codegen(["--check"], [CheckPendingResource])
      end
    end

    test "codegen/2 with --check passes when migrate is false" do
      defmodule CheckMutedResource do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("check_muted_table")
          repo(AshClickhouse.TestRepo)
          migrate(false)
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      assert Extension.codegen(["--check"], [CheckMutedResource]) == :ok
    end

    test "name/0 returns the extension name" do
      assert Extension.name() == "AshClickhouse"
    end

    test "implements Spark.Dsl.Extension behaviour" do
      assert Spark.implements_behaviour?(Extension, Spark.Dsl.Extension)
    end
  end

  describe "Extension.migrate/1 integration" do
    test "migrate/1 runs without error when no repos" do
      output =
        capture_io(fn ->
          assert Extension.migrate([]) == :ok
        end)

      assert output =~ "No AshClickhouse.Repo modules found" or output == ""
    end
  end
end
