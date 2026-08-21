defmodule AshClickhouse.MigrationRunnerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AshClickhouse.MigrationRunner
  alias AshClickhouse.TestSupport.MigrationRepo

  defp unique_module_name, do: "Migration#{System.unique_integer([:positive])}"

  def result(rows \\ []) do
    %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: rows, columns: []}
  end

  defp migration_file(module, version, up, down \\ nil) do
    down_block =
      case down do
        nil -> ""
        statements -> "\n  def down, do: #{inspect(statements)}"
      end

    """
    defmodule #{module} do
      use AshClickhouse.Schema
      def repo, do: AshClickhouse.TestSupport.MigrationRepo
      def version, do: "#{version}"
      def change, do: #{inspect(up)}
      #{down_block}
    end
    """
  end

  defp migration_file_without_version(module, up) do
    """
    defmodule #{module} do
      use AshClickhouse.Schema
      def repo, do: AshClickhouse.TestSupport.MigrationRepo
      def change, do: #{inspect(up)}
    end
    """
  end

  defp temp_migration_path(files) do
    path =
      Path.join(System.tmp_dir!(), "ash_clickhouse_runner_#{System.unique_integer([:positive])}")

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

  describe "schema helpers" do
    test "schema_migrations_table/0 returns the tracking table name" do
      assert MigrationRunner.schema_migrations_table() == "schema_migrations"
    end

    test "schema_migrations_create_sql/0 returns CREATE TABLE DDL" do
      sql = MigrationRunner.schema_migrations_create_sql()
      assert sql =~ "CREATE TABLE IF NOT EXISTS schema_migrations"
      assert sql =~ "version String"
    end

    test "ensure_schema_migrations_table/1 creates the table" do
      assert MigrationRunner.ensure_schema_migrations_table(MigrationRepo) == :ok
    end

    test "ensure_schema_migrations_table/1 returns the error when creation fails" do
      defmodule NoCreateRepo do
        def query(_statement, _params), do: {:error, "no create"}
      end

      assert MigrationRunner.ensure_schema_migrations_table(NoCreateRepo) == {:error, "no create"}
    end

    test "applied_versions/1 accepts map-shaped rows" do
      defmodule MapRowsRepo do
        def query("SELECT version FROM schema_migrations", _params),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result([%{"version" => "20240101000000"}])}
      end

      assert MigrationRunner.applied_versions(MapRowsRepo) == ["20240101000000"]
    end

    test "applied_versions/1 returns [] when the query fails" do
      defmodule ErrRepo do
        def query(_statement, _params), do: {:error, "boom"}
      end

      assert MigrationRunner.applied_versions(ErrRepo) == []
    end

    test "record_applied/2 and applied_versions/1 round-trip" do
      assert MigrationRunner.record_applied(MigrationRepo, "20240101000000") == :ok
      assert MigrationRunner.applied_versions(MigrationRepo) == ["20240101000000"]
    end

    test "record_applied/2 returns the error when the insert fails" do
      defmodule InsertErrRepo do
        def query("INSERT INTO schema_migrations" <> _, _params), do: {:error, "no insert"}
      end

      assert MigrationRunner.record_applied(InsertErrRepo, "20240101000000") ==
               {:error, "no insert"}
    end

    test "record_applied/2 passes the version as a bound parameter (no string interpolation)" do
      raw = "2024'01\\01"
      MigrationRunner.record_applied(MigrationRepo, raw)

      # With parameterized queries the raw version is stored verbatim — no
      # escaping/mangling of quotes or backslashes.
      stored = MapSet.to_list(MigrationRepo.versions())
      assert raw in stored
    end

    test "delete_applied/2 removes a version" do
      MigrationRunner.record_applied(MigrationRepo, "20240101000000")
      MigrationRunner.record_applied(MigrationRepo, "20240102000000")
      assert MigrationRunner.delete_applied(MigrationRepo, "20240101000000") == :ok
      assert MigrationRunner.applied_versions(MigrationRepo) == ["20240102000000"]
    end

    test "delete_applied/2 returns the error when the delete fails" do
      defmodule DeleteErrRepo do
        def query("ALTER TABLE schema_migrations DELETE" <> _, _params), do: {:error, "no delete"}
      end

      assert MigrationRunner.delete_applied(DeleteErrRepo, "20240101000000") ==
               {:error, "no delete"}
    end
  end

  describe "discover_migrations/1" do
    test "returns migrations sorted by version, using version/0" do
      m1 = unique_module_name()
      m2 = unique_module_name()

      path =
        temp_migration_path([
          {"20240102000000_b.exs", migration_file(m2, "20240102000000", ["SELECT 2"])},
          {"20240101000000_a.exs", migration_file(m1, "20240101000000", ["SELECT 1"])}
        ])

      assert MigrationRunner.discover_migrations(path) == [
               %{version: "20240101000000", module: Module.concat([m1])},
               %{version: "20240102000000", module: Module.concat([m2])}
             ]
    end

    test "falls back to the filename timestamp when version/0 is missing" do
      module = unique_module_name()

      path =
        temp_migration_path([
          {"20240101000000_legacy.exs", migration_file_without_version(module, ["SELECT 1"])}
        ])

      assert MigrationRunner.discover_migrations(path) == [
               %{version: "20240101000000", module: Module.concat([module])}
             ]
    end

    test "falls back to the full filename when it has no leading timestamp" do
      module = unique_module_name()

      path =
        temp_migration_path([
          {"untimestamped_migration.exs", migration_file_without_version(module, ["SELECT 1"])}
        ])

      assert MigrationRunner.discover_migrations(path) == [
               %{version: "untimestamped_migration.exs", module: Module.concat([module])}
             ]
    end

    test "ignores .exs files that define no module" do
      path =
        temp_migration_path([
          {"20240101000000_noop.exs", "# comment only, no module\n"}
        ])

      assert MigrationRunner.discover_migrations(path) == []
    end
  end

  describe "migrate/2" do
    test "applies pending migrations in version order and records versions" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(unique_module_name(), "20240101000000", [
             "CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"
           ])},
          {"20240102000000_add_name.exs",
           migration_file(unique_module_name(), "20240102000000", [
             "ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `name` String"
           ])}
        ])

      assert {:ok, %{applied: [_add_name, _create_users], skipped: []}} =
               MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)

      statements = MigrationRepo.recorded_statements()

      assert statements == [
               "CREATE TABLE IF NOT EXISTS `users` (`id` UUID)",
               "ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `name` String"
             ]

      assert MigrationRepo.versions() == MapSet.new(["20240101000000", "20240102000000"])
    end

    test "skips already applied versions" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(unique_module_name(), "20240101000000", [
             "CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"
           ])}
        ])

      MigrationRunner.record_applied(MigrationRepo, "20240101000000")

      assert {:ok, %{applied: [], skipped: [module]}} =
               MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)

      assert is_atom(module)
      assert MigrationRepo.recorded_statements() == []
    end

    test "dry_run does not execute or record" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(unique_module_name(), "20240101000000", [
             "CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"
           ])}
        ])

      log =
        capture_log(fn ->
          assert {:ok, %{applied: [_module], skipped: []}} =
                   MigrationRunner.migrate(MigrationRepo,
                     migration_path: path,
                     dry_run: true,
                     logger: true
                   )
        end)

      assert log =~ "Would apply"
      assert MigrationRepo.recorded_statements() == []
      assert MigrationRepo.versions() == MapSet.new()
    end

    test "returns an error tuple when a statement fails" do
      defmodule FailingRepo do
        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result()}

        def query("SELECT version FROM schema_migrations", []),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result()}

        def query(_statement, []), do: {:error, "boom"}
      end

      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           """
           defmodule #{unique_module_name()} do
             use AshClickhouse.Schema
             def repo, do: AshClickhouse.MigrationRunnerTest.FailingRepo
             def version, do: "20240101000000"
             def change, do: ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
           end
           """}
        ])

      assert {:error, {module, reason}} =
               MigrationRunner.migrate(FailingRepo, migration_path: path, logger: true)

      assert is_atom(module)
      assert reason =~ "failed executing"
    end

    test "returns a bare error when the tracking table cannot be created" do
      defmodule TrackingErrRepo do
        def query(_statement, []), do: {:error, %{reason: :invalid_syntax}}
      end

      assert {:error, %{reason: :invalid_syntax}} =
               MigrationRunner.migrate(TrackingErrRepo, migration_path: "/nonexistent")
    end
  end

  describe "run/2" do
    import ExUnit.CaptureIO

    test "prints a message when there are no pending migrations" do
      path = temp_migration_path([])

      output =
        capture_io(fn ->
          assert MigrationRunner.run(MigrationRepo, migration_path: path) == :ok
        end)

      assert output =~ "No pending migrations for #{inspect(MigrationRepo)}"
    end

    test "applies pending migrations and returns :ok" do
      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           migration_file(unique_module_name(), "20240101000000", [
             "CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"
           ])}
        ])

      output =
        capture_io(fn ->
          assert MigrationRunner.run(MigrationRepo, migration_path: path) == :ok
        end)

      assert output =~ "Applied"
      assert MigrationRepo.versions() == MapSet.new(["20240101000000"])
    end

    test "raises Mix.Error when a migration fails" do
      defmodule RunFailRepo do
        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result()}

        def query("SELECT version FROM schema_migrations", []),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result()}

        def query(_statement, []), do: {:error, "boom"}
      end

      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           """
           defmodule #{unique_module_name()} do
             use AshClickhouse.Schema
             def repo, do: AshClickhouse.MigrationRunnerTest.RunFailRepo
             def version, do: "20240101000000"
             def change, do: ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
           end
           """}
        ])

      assert_raise Mix.Error, fn ->
        MigrationRunner.run(RunFailRepo, migration_path: path)
      end
    end

    test "raises Mix.Error when the tracking table cannot be created" do
      defmodule RunTrackingErrRepo do
        def query(_statement, []), do: {:error, "no table"}
      end

      assert_raise Mix.Error, fn ->
        MigrationRunner.run(RunTrackingErrRepo, migration_path: "/nonexistent")
      end
    end
  end

  describe "rollback/3" do
    test "rolls back applied migrations using down/0 and removes versions" do
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

      assert {:ok, _} = MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)
      MigrationRepo.reset_statements()

      assert {:ok, %{rolled_back: [_add_name], skipped: []}} =
               MigrationRunner.rollback(MigrationRepo, "20240101000000",
                 migration_path: path,
                 logger: true
               )

      assert MigrationRepo.recorded_statements() == [
               "ALTER TABLE `users` DROP COLUMN IF NOT EXISTS `name`"
             ]

      assert MigrationRepo.versions() == MapSet.new(["20240101000000"])
    end

    test ":all rolls back everything" do
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

      assert {:ok, _} = MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)
      MigrationRepo.reset_statements()

      assert {:ok, %{rolled_back: [_module], skipped: []}} =
               MigrationRunner.rollback(MigrationRepo, :all, migration_path: path, logger: true)

      assert MigrationRepo.recorded_statements() == ["DROP TABLE IF EXISTS `users`"]
      assert MigrationRepo.versions() == MapSet.new()
    end

    test "derives inverse statements via reverse_statement/1 for legacy migrations" do
      module = unique_module_name()

      path =
        temp_migration_path([
          {"20240101000000_legacy.exs",
           migration_file(module, "20240101000000", [
             "CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"
           ])}
        ])

      assert {:ok, _} = MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)
      MigrationRepo.reset_statements()

      assert {:ok, %{rolled_back: [_m], skipped: []}} =
               MigrationRunner.rollback(MigrationRepo, :all, migration_path: path, logger: true)

      assert MigrationRepo.recorded_statements() == ["DROP TABLE IF EXISTS `users`"]
      assert MigrationRepo.versions() == MapSet.new()
    end

    test "skips migrations whose statements cannot be reversed" do
      module = unique_module_name()

      path =
        temp_migration_path([
          {"20240101000000_odd.exs",
           migration_file(module, "20240101000000", ["OPTIMIZE TABLE `users`"])}
        ])

      assert {:ok, _} = MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)

      log =
        capture_log(fn ->
          assert {:ok, %{rolled_back: [], skipped: [module]}} =
                   MigrationRunner.rollback(MigrationRepo, :all,
                     migration_path: path,
                     logger: true
                   )

          assert is_atom(module)
        end)

      assert log =~ "no reversible statements"
    end

    test "0 and \"0\" roll back every applied migration" do
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

      assert {:ok, _} = MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)
      MigrationRepo.reset_statements()

      assert {:ok, %{rolled_back: [_m]}} =
               MigrationRunner.rollback(MigrationRepo, 0, migration_path: path, logger: true)

      assert MigrationRepo.recorded_statements() == ["DROP TABLE IF EXISTS `users`"]
      assert MigrationRepo.versions() == MapSet.new()

      assert {:ok, _} = MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)
      MigrationRepo.reset_statements()

      assert {:ok, %{rolled_back: [_m]}} =
               MigrationRunner.rollback(MigrationRepo, "0", migration_path: path, logger: true)

      assert MigrationRepo.recorded_statements() == ["DROP TABLE IF EXISTS `users`"]
      assert MigrationRepo.versions() == MapSet.new()
    end

    test "an unknown target rolls back every applied migration" do
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

      assert {:ok, _} = MigrationRunner.migrate(MigrationRepo, migration_path: path, logger: true)
      MigrationRepo.reset_statements()

      assert {:ok, %{rolled_back: [_m]}} =
               MigrationRunner.rollback(MigrationRepo, :anything,
                 migration_path: path,
                 logger: true
               )

      assert MigrationRepo.recorded_statements() == ["DROP TABLE IF EXISTS `users`"]
      assert MigrationRepo.versions() == MapSet.new()
    end

    test "returns an error when a down statement fails to execute" do
      defmodule DownFailRepo do
        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result()}

        def query("SELECT version FROM schema_migrations", []),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result([["20240101000000"]])}

        def query("ALTER TABLE schema_migrations DELETE" <> _, []),
          do: {:ok, AshClickhouse.MigrationRunnerTest.result()}

        def query(_statement, []), do: {:error, "down boom"}
      end

      path =
        temp_migration_path([
          {"20240101000000_create_users.exs",
           """
           defmodule #{unique_module_name()} do
             use AshClickhouse.Schema
             def repo, do: AshClickhouse.MigrationRunnerTest.DownFailRepo
             def version, do: "20240101000000"
             def change, do: ["CREATE TABLE IF NOT EXISTS `users` (`id` UUID)"]
             def down, do: ["DROP TABLE IF EXISTS `users`"]
           end
           """}
        ])

      assert {:error, {_module, reason}} =
               MigrationRunner.rollback(DownFailRepo, :all, migration_path: path, logger: true)

      assert reason =~ "down boom"
    end
  end
end
