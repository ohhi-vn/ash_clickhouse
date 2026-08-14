defmodule AshClickhouse.ReleaseTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AshClickhouse.Release
  alias AshClickhouse.TestSupport.MigrationRepo

  defp unique_module_name, do: "Migration#{System.unique_integer([:positive])}"

  def result(rows \\ []) do
    %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: rows, columns: []}
  end

  defp migration_file(module, version, up, down \\ []) do
    """
    defmodule #{module} do
      use AshClickhouse.Schema
      def repo, do: AshClickhouse.TestSupport.MigrationRepo
      def version, do: "#{version}"
      def change, do: #{inspect(up)}
      def down, do: #{inspect(down)}
    end
    """
  end

  defp temp_migration_path(files) do
    path =
      Path.join(System.tmp_dir!(), "ash_clickhouse_release_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)

    Enum.each(files, fn {filename, body} ->
      File.write!(Path.join(path, filename), body)
    end)

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  setup do
    {:ok, _pid} = MigrationRepo.start_link()
    on_exit(fn -> MigrationRepo.stop() end)
    :ok
  end

  describe "migrate/3" do
    test "runs pending migrations and records versions" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(
             unique_module_name(),
             "20240101000000",
             ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID) ENGINE = MergeTree() ORDER BY `id`"]
           )},
          {"20240102000000_add_name.exs",
           migration_file(unique_module_name(), "20240102000000", [
             "ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `name` String"
           ])}
        ])

      assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok

      statements = MigrationRepo.recorded_statements()

      assert Enum.any?(
               statements,
               &(&1 ==
                   "CREATE TABLE IF NOT EXISTS `users` (`id` UUID) ENGINE = MergeTree() ORDER BY `id`")
             )

      assert Enum.any?(
               statements,
               &(&1 == "ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `name` String")
             )

      assert MigrationRepo.versions() == MapSet.new(["20240101000000", "20240102000000"])
    end

    test "skips migrations that were already applied" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(
             unique_module_name(),
             "20240101000000",
             ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
           )}
        ])

      AshClickhouse.MigrationRunner.record_applied(MigrationRepo, "20240101000000")

      log =
        capture_log(fn ->
          assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok
        end)

      refute Enum.any?(
               MigrationRepo.recorded_statements(),
               &(&1 == "CREATE TABLE IF NOT EXISTS `users` (`id` UUID)")
             )

      assert log =~ "0 applied"
      assert log =~ "1 skipped"
    end

    test "dry_run logs statements without executing them" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(
             unique_module_name(),
             "20240101000000",
             ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
           )}
        ])

      log =
        capture_log(fn ->
          assert Release.migrate(MigrationRepo, [MigrationRepo],
                   migration_path: path,
                   dry_run: true
                 ) == :ok
        end)

      assert log =~ "DRY RUN"
      assert log =~ "Would apply"
      assert MigrationRepo.recorded_statements() == []
      assert MigrationRepo.versions() == MapSet.new()
    end

    test "continues when database creation fails but logs an error" do
      defmodule FailingCreateRepo do
        def create_database, do: {:error, :nope}
        def database, do: "test_db"

        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query("SELECT version FROM schema_migrations", []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query(_statement, []), do: {:ok, AshClickhouse.ReleaseTest.result()}
      end

      log =
        capture_log(fn ->
          assert Release.migrate(FailingCreateRepo, [FailingCreateRepo],
                   create_database: true,
                   migration_path: "/nonexistent"
                 ) == :ok
        end)

      assert log =~ "Failed to create database: :nope"
    end

    test "skips database creation when the repo has no create_database/0" do
      defmodule NoCreateRepo do
        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query("SELECT version FROM schema_migrations", []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query(_statement, []), do: {:ok, AshClickhouse.ReleaseTest.result()}
      end

      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           """
           defmodule #{unique_module_name()} do
             use AshClickhouse.Schema
             def repo, do: AshClickhouse.ReleaseTest.NoCreateRepo
             def version, do: "20240101000000"
             def change, do: ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
             def down, do: ["DROP TABLE IF EXISTS `users`"]
           end
           """}
        ])

      log =
        capture_log(fn ->
          assert Release.migrate(NoCreateRepo, [NoCreateRepo], migration_path: path) == :ok
        end)

      assert log =~ "skipping database creation"
      assert log =~ "1 applied"
    end

    test "returns an error, not a crash, when the tracking table cannot be created" do
      defmodule BareErrorRepo do
        def create_database, do: {:ok, :created}
        def database, do: "test_db"

        def query(_statement, []),
          do: {:error, %{reason: :invalid_syntax, message: "line 3:23 : Missing ')'"}}
      end

      assert {:error, message} =
               Release.migrate(BareErrorRepo, [BareErrorRepo],
                 create_database: true,
                 migration_path: "/nonexistent"
               )

      assert message =~ "Migration failed"
      assert message =~ "Missing ')'"
    end

    test "returns an error when a migration statement fails" do
      defmodule FailingQueryRepo do
        def create_database, do: {:ok, :created}
        def database, do: "test_db"

        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query("SELECT version FROM schema_migrations", []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query(_statement, []), do: {:error, "boom"}
      end

      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           """
           defmodule #{unique_module_name()} do
             use AshClickhouse.Schema
             def repo, do: AshClickhouse.ReleaseTest.FailingQueryRepo
             def version, do: "20240101000000"
             def change, do: ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
             def down, do: ["DROP TABLE IF EXISTS `users`"]
           end
           """}
        ])

      assert {:error, message} =
               Release.migrate(FailingQueryRepo, [FailingQueryRepo], migration_path: path)

      assert message =~ "Migration failed"
    end
  end

  describe "rollback/3" do
    test "rolls back applied migrations down to a target version" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(
             unique_module_name(),
             "20240101000000",
             ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"],
             ["DROP TABLE IF EXISTS `users`"]
           )},
          {"20240102000000_add_name.exs",
           migration_file(
             unique_module_name(),
             "20240102000000",
             ["ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `name` String"],
             ["ALTER TABLE `users` DROP COLUMN IF NOT EXISTS `name`"]
           )}
        ])

      assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok
      MigrationRepo.reset_statements()

      assert Release.rollback(MigrationRepo, "20240101000000", [MigrationRepo],
               migration_path: path
             ) == :ok

      statements = MigrationRepo.recorded_statements()

      assert Enum.any?(
               statements,
               &(&1 == "ALTER TABLE `users` DROP COLUMN IF NOT EXISTS `name`")
             )

      refute Enum.any?(statements, &(&1 == "DROP TABLE IF EXISTS `users`"))
      assert MigrationRepo.versions() == MapSet.new(["20240101000000"])
    end

    test ":all rolls back every applied migration" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(
             unique_module_name(),
             "20240101000000",
             ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"],
             ["DROP TABLE IF EXISTS `users`"]
           )}
        ])

      assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok
      MigrationRepo.reset_statements()

      assert Release.rollback(MigrationRepo, :all, [MigrationRepo], migration_path: path) == :ok

      assert Enum.any?(
               MigrationRepo.recorded_statements(),
               &(&1 == "DROP TABLE IF EXISTS `users`")
             )

      assert MigrationRepo.versions() == MapSet.new()
    end

    test "is a no-op when nothing has been applied" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(
             unique_module_name(),
             "20240101000000",
             ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"],
             ["DROP TABLE IF EXISTS `users`"]
           )}
        ])

      log =
        capture_log(fn ->
          assert Release.rollback(MigrationRepo, :all, [MigrationRepo], migration_path: path) ==
                   :ok
        end)

      assert log =~ "0 rolled back"
      assert MigrationRepo.versions() == MapSet.new()
    end

    test "returns an error, not a crash, when the tracking table cannot be created" do
      defmodule BareErrorRepo do
        def create_database, do: {:ok, :created}
        def database, do: "test_db"

        def query(_statement, [], _opts \\ []),
          do: {:error, %{reason: :invalid_syntax, message: "Missing ')'"}}
      end

      assert {:error, message} =
               Release.rollback(BareErrorRepo, :all, [BareErrorRepo],
                 migration_path: "/nonexistent"
               )

      assert message =~ "Rollback failed"
      assert message =~ "Missing ')'"
    end

    test "returns an error when a down statement fails to execute" do
      defmodule FailingDownRepo do
        def create_database, do: {:ok, :created}
        def database, do: "test_db"

        def query(statement, params, opts \\ [])

        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, [], _opts),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query("SELECT version FROM schema_migrations", [], _opts),
          do: {:ok, AshClickhouse.ReleaseTest.result([["20240101000000"]])}

        def query("ALTER TABLE schema_migrations DELETE" <> _, [], _opts),
          do: {:ok, AshClickhouse.ReleaseTest.result()}

        def query(_statement, [], _opts), do: {:error, "down boom"}
      end

      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           """
           defmodule #{unique_module_name()} do
             use AshClickhouse.Schema
             def repo, do: AshClickhouse.ReleaseTest.FailingDownRepo
             def version, do: "20240101000000"
             def change, do: ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
             def down, do: ["DROP TABLE IF EXISTS `users`"]
           end
           """}
        ])

      assert {:error, message} =
               Release.rollback(FailingDownRepo, :all, [FailingDownRepo], migration_path: path)

      assert message =~ "Rollback failed"
      assert message =~ "down boom"
    end
  end

  describe "create_database/2" do
    test "returns :ok on success" do
      assert Release.create_database(MigrationRepo) == :ok
    end

    test "returns {:error, reason} on failure" do
      defmodule FailingRepo do
        def create_database, do: {:error, :nope}
      end

      assert Release.create_database(FailingRepo) == {:error, :nope}
    end

    test "returns an error and warns when the repo has no create_database/0" do
      defmodule NoDbRepo do
        def query(_statement, [], _opts \\ []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}
      end

      log =
        capture_log(fn ->
          assert Release.create_database(NoDbRepo) == {:error, :create_database_not_supported}
        end)

      assert log =~ "does not implement create_database/0"
      assert log =~ "skipping database creation"
    end
  end

  describe "migration path resolution" do
    test "defaults to priv/repo/migrations when the repo has no otp_app/0" do
      defmodule PlainRepo do
        def __ash_clickhouse_repo__, do: true
        def config, do: []
        def database, do: nil
        def create_database, do: {:ok, :created}

        def query(_statement, [], _opts \\ []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}
      end

      log =
        capture_log(fn ->
          assert Release.migrate(PlainRepo, [PlainRepo]) == :ok
        end)

      assert log =~ "0 applied"
      assert AshClickhouse.Connection.get_conn(PlainRepo) != nil
      assert AshClickhouse.Connection.stop(PlainRepo) == :ok
    end

    test "resolves the migration path from the repo app's priv dir" do
      defmodule OtpRepo do
        def __ash_clickhouse_repo__, do: true
        def config, do: []
        def otp_app, do: :ash_clickhouse
        def database, do: nil
        def create_database, do: {:ok, :created}

        def query(_statement, [], _opts \\ []),
          do: {:ok, AshClickhouse.ReleaseTest.result()}
      end

      log =
        capture_log(fn ->
          assert Release.migrate(OtpRepo, [OtpRepo]) == :ok
        end)

      assert log =~ "0 applied"
      assert AshClickhouse.Connection.stop(OtpRepo) == :ok
    end

    test "uses an explicit migration_path option over the default" do
      path = temp_migration_path([])

      log =
        capture_log(fn ->
          assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok
        end)

      assert log =~ "0 applied"
    end
  end

  describe "find_resources/2" do
    test "returns custom resources when provided in opts" do
      assert Release.find_resources([], resources: [MyApp.User]) == [MyApp.User]
    end

    test "returns empty list when no resources provided" do
      assert Release.find_resources([], []) == []
    end

    test "returns empty list for an empty resources list" do
      assert Release.find_resources([], resources: []) == []
    end
  end
end
