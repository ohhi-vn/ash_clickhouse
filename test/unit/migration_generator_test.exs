defmodule AshClickhouse.MigrationGeneratorTest do
  @moduledoc """
  Unit tests for AshClickhouse.MigrationGenerator.

  The generator normally discovers resources via `Helpers.find_resources/0`
  (which scans modules compiled into the app). Tests pass an explicit
  `:resources` option plus temporary `:migration_path` / `:snapshot_path`
  directories so the file-writing behaviour can be exercised in isolation.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias AshClickhouse.MigrationGenerator

  defmodule GenResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("gen_users")
      repo(AshClickhouse.TestRepo)
      database("gen_db")
      engine("MergeTree()")
      order_by("id")
      partition_by("toYYYYMM(created_at)")

      index(name: :idx_name, expression: "name", type: "minmax", granularity: 4)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:age, :integer, allow_nil?: false)
      attribute(:created_at, :utc_datetime)
    end
  end

  defmodule MutedResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("muted_table")
      repo(AshClickhouse.TestRepo)
      migrate(false)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defp resource_key(resource) do
    resource
    |> Module.split()
    |> Enum.map_join(".", &Macro.underscore/1)
  end

  defp temp_dirs do
    base =
      Path.join(System.tmp_dir!(), "ash_clickhouse_gen_#{System.unique_integer([:positive])}")

    migration_path = Path.join(base, "migrations")
    snapshot_path = Path.join(base, "snapshots")
    File.mkdir_p!(migration_path)
    File.mkdir_p!(snapshot_path)

    on_exit(fn -> File.rm_rf!(base) end)
    {migration_path, snapshot_path}
  end

  defp snapshot_path_for(snapshot_path, resource) do
    Path.join(snapshot_path, "#{resource_key(resource)}.json")
  end

  defp write_snapshot(snapshot_path, resource, contents) do
    File.write!(snapshot_path_for(snapshot_path, resource), Jason.encode!(contents))
  end

  describe "generate/1 with explicit resources" do
    test "writes a migration file and snapshot for each resource" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [GenResource],
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      files = Path.wildcard(Path.join(migration_path, "*.exs"))
      assert length(files) == 1

      [file] = files
      contents = File.read!(file)

      assert contents =~ "defmodule AshClickhouse.Migrations.Migrate"
      assert contents =~ "GenResource do"
      assert contents =~ "use AshClickhouse.Schema"
      assert contents =~ "def repo, do: AshClickhouse.TestRepo"
      assert contents =~ "def version, do: "
      assert contents =~ "CREATE TABLE IF NOT EXISTS"
      assert contents =~ "`gen_users`"
      assert contents =~ "INDEX `idx_name`"
      assert contents =~ "def down do"
      assert contents =~ "DROP TABLE IF EXISTS"

      assert File.exists?(snapshot_path_for(snapshot_path, GenResource))
    end

    test "uses a custom name in the filename and module" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [GenResource],
               name: "create_users",
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      [file] = Path.wildcard(Path.join(migration_path, "*.exs"))
      assert Path.basename(file) =~ "create_users"

      contents = File.read!(file)
      assert contents =~ "defmodule AshClickhouse.Migrations.CreateUsers"
      assert contents =~ "GenResource do"
    end

    test "skips resources with migrate? false" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [MutedResource],
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      assert Path.wildcard(Path.join(migration_path, "*.exs")) == []
    end

    test "is a no-op when the resource has not changed since the last snapshot" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [GenResource],
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      assert MigrationGenerator.generate(
               resources: [GenResource],
               check: true,
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      assert Path.wildcard(Path.join(migration_path, "*.exs")) |> length() == 1
    end

    test "check: true raises PendingCodegen when changes are pending" do
      {migration_path, snapshot_path} = temp_dirs()

      assert_raise Ash.Error.Framework.PendingCodegen, fn ->
        MigrationGenerator.generate(
          resources: [GenResource],
          check: true,
          migration_path: migration_path,
          snapshot_path: snapshot_path
        )
      end
    end

    test "check: true without pending changes prints nothing and returns :ok" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [GenResource],
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      output =
        capture_io(fn ->
          assert MigrationGenerator.generate(
                   resources: [GenResource],
                   check: true,
                   migration_path: migration_path,
                   snapshot_path: snapshot_path
                 ) == :ok
        end)

      assert output == ""
    end

    test "prints a message when there are no changes and no check flag" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [GenResource],
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      output =
        capture_io(fn ->
          assert MigrationGenerator.generate(
                   resources: [GenResource],
                   migration_path: migration_path,
                   snapshot_path: snapshot_path
                 ) == :ok
        end)

      assert output =~ "No changes detected"
    end

    test "dry_run prints the files without writing anything" do
      {migration_path, snapshot_path} = temp_dirs()

      output =
        capture_io(fn ->
          assert MigrationGenerator.generate(
                   resources: [GenResource],
                   dry_run: true,
                   migration_path: migration_path,
                   snapshot_path: snapshot_path
                 ) == :ok
        end)

      assert output =~ "---"
      assert output =~ "CREATE TABLE IF NOT EXISTS"
      assert output =~ "defmodule"

      assert Path.wildcard(Path.join(migration_path, "*.exs")) == []
      refute File.exists?(snapshot_path_for(snapshot_path, GenResource))
    end

    test "dev: true writes _dev suffixed migration and snapshot files" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [GenResource],
               dev: true,
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      [file] = Path.wildcard(Path.join(migration_path, "*_dev.exs"))
      assert Path.basename(file) =~ "_dev.exs"
      assert File.exists?(Path.join(snapshot_path, "#{resource_key(GenResource)}_dev.json"))
    end

    test "a non-dev run cleans up _dev migration and snapshot files" do
      {migration_path, snapshot_path} = temp_dirs()

      assert MigrationGenerator.generate(
               resources: [GenResource],
               dev: true,
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      assert MigrationGenerator.generate(
               resources: [GenResource],
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      assert Path.wildcard(Path.join(migration_path, "*_dev.exs")) == []
      refute File.exists?(Path.join(snapshot_path, "#{resource_key(GenResource)}_dev.json"))
    end

    test "generates ALTER statements and downs when the schema gained columns and indexes" do
      {migration_path, snapshot_path} = temp_dirs()

      write_snapshot(snapshot_path, GenResource, %{
        "resource" => resource_key(GenResource),
        "table" => "gen_users",
        "engine" => "MergeTree()",
        "order_by" => "id",
        "partition_by" => "toYYYYMM(created_at)",
        "attributes" => [
          %{"name" => "id", "type" => "UUID", "allow_nil?" => false}
        ],
        "indexes" => []
      })

      assert MigrationGenerator.generate(
               resources: [GenResource],
               migration_path: migration_path,
               snapshot_path: snapshot_path
             ) == :ok

      [file] = Path.wildcard(Path.join(migration_path, "*.exs"))
      contents = File.read!(file)

      assert contents =~
               "ALTER TABLE `gen_users` ADD COLUMN IF NOT EXISTS `name` String"

      assert contents =~
               "ALTER TABLE `gen_users` ADD COLUMN IF NOT EXISTS `age` Int64"

      assert contents =~
               "ALTER TABLE `gen_users` ADD INDEX IF NOT EXISTS `idx_name` (name) TYPE minmax GRANULARITY 4"

      assert contents =~
               "ALTER TABLE `gen_users` DROP COLUMN IF NOT EXISTS `name`"

      assert contents =~
               "ALTER TABLE `gen_users` DROP INDEX IF NOT EXISTS `idx_name`"

      refute contents =~ "CREATE TABLE IF NOT EXISTS"
    end
  end

  describe "parse_codegen_argv/1" do
    alias AshClickhouse.DataLayer.Extension

    test "extracts flags and the name" do
      assert Extension.parse_codegen_argv(["--dry-run", "--name", "create_users"]) ==
               [name: "create_users", dry_run: true]

      assert Extension.parse_codegen_argv(["--dev", "--check"]) == [dev: true, check: true]
      assert Extension.parse_codegen_argv([]) == []
    end
  end
end
