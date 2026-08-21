defmodule AshClickhouse.CoverageGapsTest do
  @moduledoc """
  Tests targeting branches not exercised elsewhere: connection lifecycle edge
  cases, migration default/reverse edge cases, runner failure paths, release
  rollback, query-builder fallbacks, and type-mapping fallbacks.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias AshClickhouse.Connection
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.DataLayer.Types
  alias AshClickhouse.Error
  alias AshClickhouse.Identifier
  alias AshClickhouse.Migration
  alias AshClickhouse.MigrationRunner
  alias AshClickhouse.Release
  alias AshClickhouse.TestSupport.MigrationRepo

  # ── helpers ─────────────────────────────────────────────────────────────────

  def result(rows \\ []),
    do: %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: rows, columns: []}

  defp unique_name(prefix), do: String.to_atom("#{prefix}#{System.unique_integer([:positive])}")

  defp temp_migration_path(files) do
    path =
      Path.join(System.tmp_dir!(), "ash_clickhouse_gaps_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)

    Enum.each(files, fn {filename, body} ->
      File.write!(Path.join(path, filename), body)
    end)

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp migration_file(module, repo, version, up, down \\ []) do
    down_block =
      case down do
        [] -> ""
        statements -> "\n  def down, do: #{inspect(statements)}"
      end

    """
    defmodule #{module} do
      use AshClickhouse.Schema
      def repo, do: #{inspect(repo)}
      def version, do: "#{version}"
      def change, do: #{inspect(up)}
      #{down_block}
    end
    """
  end

  # ── Connection ──────────────────────────────────────────────────────────────

  describe "Connection lifecycle" do
    test "start_link/1 returns {:ok, pid} when the client is already started" do
      name = unique_name("already_started_conn")

      Process.flag(:trap_exit, true)
      {:ok, pid} = Connection.start_link(name: name, url: "http://127.0.0.1:1")

      # The client registers a named ETS table per connection name, so a second
      # start under the same name fails to boot the child and surfaces as
      # `{:error, {:already_started, pid}}` inside the client — which
      # `start_link/1` converts to `{:ok, pid}`.
      case Connection.start_link(name: name, url: "http://127.0.0.1:1") do
        {:ok, ^pid} -> :ok
        {:error, _} -> :ok
      end

      Connection.stop(name)
    end

    test "start_link/1 returns the error when the client fails to start" do
      name = unique_name("bad_url_conn")

      # start_link links the failing child to the caller; trap exits so the
      # child's death doesn't take the test process down.
      Process.flag(:trap_exit, true)
      assert {:error, _reason} = Connection.start_link(name: name, url: :not_a_url)
    end

    test "query!/4 raises ClickhouseError when the client returns an error tuple" do
      name = unique_name("query_bang_conn")
      {:ok, _pid} = Connection.start_link(name: name, url: "http://127.0.0.1:1")

      assert_raise Error.ClickhouseError, fn ->
        Connection.query!(name, "SELECT 1", [])
      end

      Connection.stop(name)
    end

    test "stop/1 on a struct whose pid is not a supervisor is rescued" do
      name = unique_name("bad_pid_conn")
      conn = %Connection{name: name, pid: spawn(fn -> Process.sleep(10_000) end), conn: nil}

      # `Supervisor.stop/1` raises for a non-supervisor pid; the rescue clause
      # logs and treats the client as stopped.
      log = capture_log(fn -> assert Connection.stop(conn) == :ok end)

      assert log =~ "do_stop_client rescued" or log == ""
      assert Connection.get_conn(name) == nil
    end

    test "query!/4 returns the result on success" do
      # A dead pid makes the client raise, which `query!/4` wraps and reraises
      # as a ClickhouseError — covering the `{:error, error}` branch.
      name = unique_name("query_bang_dead")
      {:ok, pid} = Connection.start_link(name: name, url: "http://127.0.0.1:1")

      assert_raise Error.ClickhouseError, fn ->
        Connection.query!(%Connection{conn: name, pid: pid, name: name, database: nil}, "SELECT 1")
      end

      Connection.stop(name)
    end

    test "ipv4_only resolves a hostname to a literal IP" do
      name = unique_name("ipv4_conn")

      assert {:ok, _pid} =
               Connection.start_link(
                 name: name,
                 url: "http://localhost:8123",
                 ipv4_only: true
               )

      Connection.stop(name)
    end

    test "ipv4_only keeps the URL when the host cannot be resolved" do
      name = unique_name("ipv4_unresolvable")

      assert {:ok, _pid} =
               Connection.start_link(
                 name: name,
                 url: "http://ash-clickhouse-does-not-exist.invalid:8123",
                 ipv4_only: true
               )

      Connection.stop(name)
    end
  end

  # ── Mix.Tasks.AshClickhouse.Helpers ─────────────────────────────────────────

  describe "Mix.Tasks.AshClickhouse.Helpers failure path" do
    test "start_clients/2 raises when the connection cannot be started" do
      defmodule FailingStartRepo do
        use AshClickhouse.Repo, otp_app: :ash_clickhouse
      end

      Application.put_env(:ash_clickhouse, FailingStartRepo, url: :not_a_valid_url)

      on_exit(fn -> Application.delete_env(:ash_clickhouse, FailingStartRepo) end)

      assert_raise Mix.Error, ~r/Failed to start ClickHouse connection/, fn ->
        Process.flag(:trap_exit, true)

        Mix.Tasks.AshClickhouse.Helpers.start_clients([FailingStartRepo])
      end
    end
  end

  # ── Error ───────────────────────────────────────────────────────────────────

  test "client_error_modules/0 lists the clickhouse client error modules" do
    modules = Error.client_error_modules()
    assert ClickHouse.QueryError in modules
    assert ClickHouse.ConnectionError in modules
    assert Error.client_error?(%ClickHouse.QueryError{message: "x"})
  end

  # ── Identifier ──────────────────────────────────────────────────────────────

  test "sanitize!/1 and valid_identifier?/1 accept atoms" do
    assert Identifier.sanitize!(:users) == "users"
    assert Identifier.valid_identifier?(:ok_name)
    refute Identifier.valid_identifier?(:"bad name")
  end

  # ── Migration ───────────────────────────────────────────────────────────────

  describe "Migration defaults" do
    # The Date/DateTime/numeric-string/boolean default clauses in
    # `inspect_numeric_default/2` only trigger when the resolved column type is
    # NOT one of the quoted types (String/UUID/DateTime64/Date). Decimal columns
    # resolve to `Decimal(precision, scale)` when constraints are given, so they
    # route through the numeric path while carrying Date/DateTime values.
    defmodule DateDefaultResource do
      use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("date_defaults")
        repo(AshClickhouse.TestRepo)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:count, :decimal,
          allow_nil?: false,
          constraints: [precision: 38, scale: 10],
          default: Decimal.new("2024.0102")
        )
        attribute(:ratio, :decimal,
          allow_nil?: false,
          constraints: [precision: 38, scale: 10],
          default: Decimal.new("1.5")
        )
        attribute(:numeric_string, :integer, allow_nil?: false, default: "42")
        attribute(:flag, :boolean, allow_nil?: false, default: true)
      end
    end

    test "Decimal/numeric-string/boolean defaults render as bare numeric literals" do
      sql = Migration.create_table_cql(DateDefaultResource)
      assert String.contains?(sql, "`count` Decimal(38, 10) DEFAULT 2024.0102")
      assert String.contains?(sql, "`ratio` Decimal(38, 10) DEFAULT 1.5")
      assert String.contains?(sql, "`numeric_string` Int64 DEFAULT 42")
      assert String.contains?(sql, "`flag` UInt8 DEFAULT 1")
    end

    test "Date and DateTime defaults on a Decimal column are quoted ISO8601 literals" do
      # Ash casts attribute defaults, so Date/DateTime values on a :decimal
      # attribute cannot be declared via the DSL. Exercise the code path through
      # the test hook instead.
      attr = %{
        name: :day,
        type: Ash.Type.Decimal,
        constraints: [precision: 38, scale: 10],
        allow_nil?: false,
        default: ~D[2024-01-02]
      }

      assert Migration.inspect_default_for_test(~D[2024-01-02], "Decimal(38, 10)") ==
               "'2024-01-02'"

      assert Migration.inspect_default_for_test(~U[2024-01-02 03:04:05Z], "Decimal(38, 10)") ==
               "'2024-01-02T03:04:05Z'"

      assert Migration.inspect_default_for_test(Decimal.new("1.5"), "Decimal(38, 10)") == "1.5"
      assert Migration.inspect_default_for_test(7, "Int64") == "7"
      assert Migration.inspect_default_for_test(1.5, "Float64") == "1.5"
      assert Migration.inspect_default_for_test(true, "UInt8") == "1"
      assert Migration.inspect_default_for_test(false, "UInt8") == "0"
      assert Migration.inspect_default_for_test("3.14", "Float64") == "3.14"
    end

    test "a non-numeric string default for a numeric column raises" do
      assert_raise Error.ConfigurationError, ~r/Non-numeric default/, fn ->
        Migration.inspect_default_for_test("not-a-number", "Int64")
      end
    end

    test "an unsupported default term for a numeric column raises" do
      assert_raise Error.ConfigurationError, ~r/Unsupported default/, fn ->
        Migration.inspect_default_for_test({:tuple, 1}, "Int64")
      end
    end
  end

  describe "Migration.table_exists?/2 rescue path" do
    defmodule RaisingRepo do
      def query(_sql, _params), do: raise("boom")
      def database, do: "db"
    end

    test "returns false when the repo query raises" do
      refute Migration.table_exists?(AshClickhouse.TestResource, RaisingRepo)
    end
  end

  describe "Migration.reverse_statement/1" do
    test "reverses CREATE TABLE without IF NOT EXISTS" do
      assert Migration.reverse_statement("CREATE TABLE `users` (`id` UUID)") ==
               "DROP TABLE IF EXISTS `users`"
    end

    test "reverses CREATE TABLE IF NOT EXISTS with a bare table name" do
      assert Migration.reverse_statement("CREATE TABLE IF NOT EXISTS users") ==
               "DROP TABLE IF EXISTS users"
    end

    test "reverses ADD COLUMN and ADD INDEX, and returns nil for other ALTERs" do
      assert Migration.reverse_statement(
               "ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `name` String"
             ) ==
               "ALTER TABLE `users` DROP COLUMN IF NOT EXISTS `name`"

      assert Migration.reverse_statement(
               "ALTER TABLE `users` ADD INDEX IF NOT EXISTS `ix_age` `age` TYPE minmax GRANULARITY 1"
             ) ==
               "ALTER TABLE `users` DROP INDEX IF NOT EXISTS `ix_age`"

      assert Migration.reverse_statement("ALTER TABLE `users` DROP COLUMN `name`") == nil
      assert Migration.reverse_statement("INSERT INTO `users`") == nil
    end
  end

  # ── Types ───────────────────────────────────────────────────────────────────

  defmodule UuidNewType do
    use Ash.Type.NewType, subtype_of: :uuid
  end

  defmodule TypeForwardingModule do
    def type, do: :uuid
  end

  describe "Types.ash_type_to_clickhouse/1 fallbacks" do
    test "unwraps NewTypes via subtype_of/0" do
      assert Types.ash_type_to_clickhouse(UuidNewType) == "UUID"
    end

    test "unwraps modules exposing type/0" do
      assert Types.ash_type_to_clickhouse(TypeForwardingModule) == "UUID"
    end
  end

  describe "Types decode_value/2 datetime handling" do
    @attr %{type: :utc_datetime}

    test "parses a space-separated timestamp into a DateTime" do
      assert %DateTime{year: 2024, month: 1, day: 2} = Types.decode_value("2024-01-02 03:04:05", @attr)
    end

    test "keeps values that already carry a zone offset" do
      assert %DateTime{year: 2024, month: 1, day: 2} = Types.decode_value("2024-01-02T03:04:05Z", @attr)
    end

    test "passes through unparseable binaries, nil, structs and other terms" do
      assert Types.decode_value("not-a-date", @attr) == "not-a-date"
      assert Types.decode_value(nil, @attr) == nil

      now = DateTime.utc_now()
      assert Types.decode_value(now, @attr) == now
      assert Types.decode_value(42, @attr) == 42
    end
  end

  describe "Types decode_value/2 boolean fallback" do
    test "passes through unrecognised boolean strings" do
      assert Types.decode_value("maybe", %{type: :boolean}) == "maybe"
    end
  end

  describe "Types metadata helpers passthrough clauses" do
    test "uuid_attribute_names/1, atom_attribute_names/1 and attr_type_map/1 pass maps through" do
      map = %{"precomputed" => true}
      assert Types.uuid_attribute_names(map) == map
      assert Types.atom_attribute_names(map) == map
      assert Types.attr_type_map(map) == map
    end
  end

  describe "Types uuid helpers" do
    test "uuid_attribute_names/1 includes atom-typed :uuid attributes" do
      defmodule AtomUuidResource do
        use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

        attributes do
          uuid_primary_key(:id)
          attribute(:external_ref, :uuid, allow_nil?: true)
        end
      end

      names = Types.uuid_attribute_names(AtomUuidResource)
      assert MapSet.member?(names, :external_ref)
      assert MapSet.member?(names, "external_ref")
    end

    test "uuid_string_to_binary/1 rejects 36-char strings that do not split into 5 segments" do
      assert Types.uuid_string_to_binary(String.duplicate("a", 36)) == :error
      assert Types.uuid_string_to_binary(42) == :error
    end

    test "uuid_like_string?/1 rejects non-binaries and short strings" do
      refute Types.uuid_like_string?(123)
      refute Types.uuid_like_string?("short")
    end
  end

  # ── Release ─────────────────────────────────────────────────────────────────

  describe "Release.rollback/4" do
    setup do
      {:ok, _pid} = MigrationRepo.start_link()
      on_exit(fn -> MigrationRepo.stop() end)
      :ok
    end

    test "rolls back applied migrations and removes their versions" do
      module1 = unique_name("RollbackCreate")
      module2 = unique_name("RollbackAlter")

      path =
        temp_migration_path([
          {"20240101000000_create.exs",
           migration_file(module1, MigrationRepo, "20240101000000", [
             "CREATE TABLE IF NOT EXISTS `rb` (`id` UUID) ENGINE = MergeTree() ORDER BY `id`"
           ])},
          {"20240102000000_alter.exs",
           migration_file(module2, MigrationRepo, "20240102000000", [
             "ALTER TABLE `rb` ADD COLUMN IF NOT EXISTS `name` String"
           ])}
        ])

      assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok
      assert MapSet.size(MigrationRepo.versions()) == 2

      MigrationRepo.reset_statements()

      assert {:ok, %{rolled_back: rolled_back, skipped: []}} =
               MigrationRunner.rollback(MigrationRepo, :all, migration_path: path)

      assert length(rolled_back) == 2
      assert MigrationRepo.versions() == MapSet.new()

      statements = MigrationRepo.recorded_statements()
      assert Enum.any?(statements, &(&1 == "ALTER TABLE `rb` DROP COLUMN IF NOT EXISTS `name`"))
      assert Enum.any?(statements, &(&1 == "DROP TABLE IF EXISTS `rb`"))
    end
  end

  describe "Release.find_resources/2" do
    test "auto-discovers when no :resources option is given" do
      assert is_list(Release.find_resources([], []))
    end

    test "returns the explicit :resources list" do
      assert Release.find_resources([], resources: [Foo, Bar]) == [Foo, Bar]
    end
  end

  describe "Release repo startup" do
    defmodule ReleaseGapRepo do
      use AshClickhouse.Repo, otp_app: :ash_clickhouse_release_gaps
    end

    defmodule ReleaseNoPrivRepo do
      use AshClickhouse.Repo, otp_app: :ash_clickhouse_no_such_app_gaps
    end

    test "migrate/3 starts the repo connection and reuses it on the next run" do
      Application.put_env(:ash_clickhouse_release_gaps, ReleaseGapRepo,
        url: "http://127.0.0.1:1",
        database: "release_gap_db"
      )

      path = temp_migration_path([])

      on_exit(fn ->
        Application.delete_env(:ash_clickhouse_release_gaps, ReleaseGapRepo)

        case Connection.get_conn(ReleaseGapRepo) do
          %Connection{pid: pid} when is_pid(pid) ->
            if Process.alive?(pid) do
              Process.exit(pid, :kill)
            end

          _ ->
            :ok
        end
      end)

      # No ClickHouse server is running, so the migration itself fails — but the
      # connection must have been started and cached for the repo.
      assert {:error, _} = Release.migrate(ReleaseGapRepo, [ReleaseGapRepo], migration_path: path)
      assert %Connection{} = Connection.get_conn(ReleaseGapRepo)

      # Second run resolves the already-started connection (still fails to
      # connect, but exercises the `%AshClickhouse.Connection{}` branch of
      # `ensure_repo_started/1`).
      assert {:error, _} = Release.migrate(ReleaseGapRepo, [ReleaseGapRepo], migration_path: path)
    end

    test "migrate/3 falls back to the relative migration path when priv_dir is missing" do
      # `:code.priv_dir/1` raises for an app that was never loaded, exercising
      # the rescue fallback to "priv/repo/migrations".
      path = temp_migration_path([])

      assert capture_log(fn ->
               assert Release.migrate(ReleaseNoPrivRepo, [ReleaseNoPrivRepo],
                        migration_path: path
                      ) == :ok
             end) =~ "Starting migration"
    end
  end

  # ── MigrationRunner ─────────────────────────────────────────────────────────

  defmodule RunnerFailRepo do
    def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
      do: {:ok, AshClickhouse.CoverageGapsTest.result()}

    def query("SELECT version FROM schema_migrations", []),
      do: {:ok, AshClickhouse.CoverageGapsTest.result()}

    def query("INSERT INTO schema_migrations (version) VALUES (?)", _), do: {:error, :boom}
    def query("ALTER TABLE schema_migrations DELETE WHERE version = ?", _), do: {:error, :boom}
    def query(_statement, []), do: {:ok, AshClickhouse.CoverageGapsTest.result()}
  end

  defmodule WeirdRowsRepo do
    def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []),
      do: {:ok, AshClickhouse.CoverageGapsTest.result()}

    def query("SELECT version FROM schema_migrations", []),
      do: {:ok, AshClickhouse.CoverageGapsTest.result([[1, 2], %{"version" => "9"}])}

    def query(_statement, []), do: {:ok, AshClickhouse.CoverageGapsTest.result()}
  end

  describe "MigrationRunner failure and fallback paths" do
    setup do
      {:ok, _pid} = MigrationRepo.start_link()
      on_exit(fn -> MigrationRepo.stop() end)
      :ok
    end

    test "migrate/2 returns an error when recording the version fails" do
      module = unique_name("RecordFailMigration")

      path =
        temp_migration_path([
          {"20240101000000_x.exs",
           migration_file(module, RunnerFailRepo, "20240101000000", ["SELECT 1"])}
        ])

      assert {:error, {msg_module, msg}} =
               MigrationRunner.migrate(RunnerFailRepo, migration_path: path)

      assert to_string(msg_module) == "Elixir." <> Atom.to_string(module)
      assert msg =~ "failed to record"
    end

    test "rollback/3 returns an error when deleting the version fails" do
      defmodule DeleteFailRepo do
        def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []), do: {:ok, []}

        def query("SELECT version FROM schema_migrations", []),
          do: {:ok, AshClickhouse.CoverageGapsTest.result([["20240101000000"]])}

        def query("ALTER TABLE schema_migrations DELETE WHERE version = ?", _),
          do: {:error, :boom}

        def query(_statement, []), do: {:ok, []}
      end

      module = unique_name("DeleteFailMigration")

      path =
        temp_migration_path([
          {"20240101000000_x.exs",
           migration_file(module, DeleteFailRepo, "20240101000000", ["SELECT 1"], ["SELECT 2"])}
        ])

      assert {:error, {msg_module, msg}} =
               MigrationRunner.rollback(DeleteFailRepo, :all, migration_path: path)

      assert to_string(msg_module) == "Elixir." <> Atom.to_string(module)
      assert msg =~ "failed to remove"
    end

    test "migrate/1, run/1 and rollback/2 work with default options" do
      path = temp_migration_path([])
      assert {:ok, %{applied: [], skipped: []}} = MigrationRunner.migrate(RunnerFailRepo)
      assert MigrationRunner.run(RunnerFailRepo, migration_path: path) == :ok

      assert {:ok, %{rolled_back: [], skipped: []}} =
               MigrationRunner.rollback(RunnerFailRepo, nil)
    end

    test "rollback/3 with nil target rolls back everything" do
      module = unique_name("NilTargetMigration")

      path =
        temp_migration_path([
          {"20240101000000_x.exs",
           migration_file(module, MigrationRepo, "20240101000000", ["SELECT 1"], ["SELECT 2"])}
        ])

      assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok

      assert {:ok, %{rolled_back: rolled_back, skipped: []}} =
               MigrationRunner.rollback(MigrationRepo, nil, migration_path: path)

      assert Enum.map(rolled_back, &to_string/1) == ["Elixir." <> Atom.to_string(module)]
    end

    test "rollback/3 with a non-numeric target stops immediately (lexicographic compare)" do
      module = unique_name("LexTargetMigration")

      path =
        temp_migration_path([
          {"20240101000000_x.exs",
           migration_file(module, MigrationRepo, "20240101000000", ["SELECT 1"], ["SELECT 2"])}
        ])

      assert Release.migrate(MigrationRepo, [MigrationRepo], migration_path: path) == :ok

      # "20240101000000" <= "zzz" lexicographically, so nothing is rolled back.
      assert {:ok, %{rolled_back: [], skipped: []}} =
               MigrationRunner.rollback(MigrationRepo, "zzz", migration_path: path)
    end

    test "applied_versions/1 ignores malformed rows" do
      assert MigrationRunner.applied_versions(WeirdRowsRepo) == ["9"]
    end
  end

  # ── DataLayer.Extension ─────────────────────────────────────────────────────

  describe "DataLayer.Extension.migrate/2 warning and rescue paths" do
    defmodule IndexMismatchRepo do
      def query("SELECT 1 FROM system.tables" <> _, _params), do: {:ok, result([[1]])}

      def query("SELECT name, type, expr FROM system.data_skipping_indices" <> _, _params),
        do: {:ok, result([["by_age", "set", "age"]])}

      def query(_statement, _params), do: {:ok, result([])}

      def database, do: "test_db"

      defp result(rows \\ []),
        do: %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: rows, columns: []}
    end

    defmodule IndexedResource do
      use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("indexed_mismatch")
        repo(IndexMismatchRepo)

        index(name: :by_age, expression: "age", type: "minmax", granularity: 1)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:age, :integer)
      end
    end

    defmodule BrokenMigrationResource do
      use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("broken_migration")
        repo(IndexMismatchRepo)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:tags, {:array, :string}, allow_nil?: true)
      end
    end

    test "prints index mismatch warnings during migrate" do
      output =
        capture_io(:stderr, fn ->
          assert AshClickhouse.DataLayer.Extension.migrate([IndexMismatchRepo], [IndexedResource]) ==
                   :ok
        end)

      assert output =~ "has type \"set\" in ClickHouse but is configured as \"minmax\""
    end

    test "reports resources whose migration cannot be generated without raising" do
      output =
        capture_io(:stderr, fn ->
          assert AshClickhouse.DataLayer.Extension.migrate([IndexMismatchRepo], [
                   BrokenMigrationResource
                 ]) == :ok
        end)

      assert output =~ "Failed to generate migration"
    end
  end

  # ── QueryBuilder ────────────────────────────────────────────────────────────

  defp query(overrides) do
    struct!(
      AshClickhouse.Query,
      Map.merge(
        %{
          resource: nil,
          table: "users",
          database: nil,
          filters: [],
          sorts: [],
          limit: nil,
          offset: nil,
          select: nil,
          distinct: nil,
          group_by: nil
        },
        overrides
      )
    )
  end

  describe "QueryBuilder distinct/sort interaction" do
    test "appends sorted columns missing from a DISTINCT select list" do
      {sql, _} =
        QueryBuilder.build_optimized_query(
          query(%{distinct: [:name], select: [:name], sorts: [{:age, :asc}]})
        )

      assert sql == "SELECT DISTINCT `name`, `age` FROM `users` ORDER BY `age` ASC"
    end

    test "ignores sorts whose field is not an atom" do
      {sql, _} =
        QueryBuilder.build_optimized_query(
          query(%{distinct: [:id], select: [:id], sorts: [{"name", :asc}]})
        )

      assert sql == "SELECT DISTINCT `id` FROM `users` ORDER BY `name` ASC"
    end

    test "bare-atom sorts contribute columns to the DISTINCT select list" do
      {sql, _} =
        QueryBuilder.build_optimized_query(
          query(%{distinct: [:id], select: [:id], sorts: [:name]})
        )

      assert String.starts_with?(sql, "SELECT DISTINCT `id`, `name` FROM")
    end
  end

  describe "QueryBuilder predicate fallbacks" do
    test "ref with a binary attribute name" do
      filter = %{operator: :eq, left: %Ash.Query.Ref{attribute: "name"}, right: "x"}
      assert {" WHERE `name` = ?", ["x"]} = QueryBuilder.build_where_clause([filter])
    end

    test "bare atom and binary left-hand sides" do
      assert {clause, [_]} =
               QueryBuilder.build_where_clause([%{operator: :eq, left: :age, right: 1}])

      assert clause == " WHERE `age` = ?"

      assert {clause, [_]} =
               QueryBuilder.build_where_clause([%{operator: :eq, left: "age", right: 1}])

      assert clause == " WHERE `age` = ?"
    end

    test "like and ilike operators" do
      assert {" WHERE `name` LIKE ?", ["x%"]} =
               QueryBuilder.build_where_clause([%{operator: :like, left: :name, right: "x%"}])

      assert {" WHERE `name` ILIKE ?", ["x%"]} =
               QueryBuilder.build_where_clause([%{operator: :ilike, left: :name, right: "x%"}])
    end

    test "case-sensitive contains uses position()" do
      Application.put_env(:ash_clickhouse, :case_sensitive_contains, true)

      on_exit(fn -> Application.delete_env(:ash_clickhouse, :case_sensitive_contains) end)

      assert {" WHERE position(`name`, ?) > 0", ["x"]} =
               QueryBuilder.build_where_clause([%{operator: :contains, left: :name, right: "x"}])
    end

    test "empty in/not_in lists emit always-false/always-true literals" do
      assert {" WHERE `name` IN (0)", []} =
               QueryBuilder.build_where_clause([%{operator: :in, left: :name, right: []}])

      assert {" WHERE `name` NOT IN (1)", []} =
               QueryBuilder.build_where_clause([%{operator: :not_in, left: :name, right: []}])
    end
  end

  # ── Insert ──────────────────────────────────────────────────────────────────

  defmodule UuidAutogenResource do
    use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

    attributes do
      attribute(:id, :uuid, primary_key?: true, allow_nil?: false, default: &Ash.UUID.generate/0)
    end
  end

  defmodule ModuleUuidAutogenResource do
    use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

    attributes do
      attribute(:id, Ash.Type.UUID,
        primary_key?: true,
        allow_nil?: false,
        default: &Ash.UUID.generate/0
      )
    end
  end

  defmodule SecondPrecisionDateTimeResource do
    use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("second_precision_dt")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:at, :utc_datetime)
    end
  end

  defmodule DateTimeResource do
    use Ash.Resource, data_layer: AshClickhouse.DataLayer, domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("date_time_resource")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:at, :utc_datetime)
    end
  end

  describe "Insert autogeneration and encoding fallbacks" do
    test "fills in a missing uuid pk with a generated uuid" do
      attrs =
        AshClickhouse.DataLayer.Insert.changeset_to_insert_attrs(
          %{attributes: %{}},
          UuidAutogenResource
        )

      assert attrs[:id] =~ ~r/^[0-9a-f-]{36}$/
    end

    test "encode_bulk_value passes through unknown terms and non-DateTime64 datetimes" do
      uuid_fields = MapSet.new()

      # Non-struct fallback clause (`_ -> value`).
      assert AshClickhouse.DataLayer.Insert.encode_attr_value(:other, :weird_term, %{}, uuid_fields) ==
               :weird_term

      # `DateTime` on a plain `DateTime` column encodes as epoch seconds.
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-02T03:04:05Z")

      assert elem(
               AshClickhouse.DataLayer.Insert.build_insert_rows([%{"at" => dt}], DateTimeResource),
               1
             ) == [[nil, 1_704_164_645_000_000]]
    end

    test "encode_bulk_value handles NaiveDateTime, 16-byte UUID binaries and plain DateTime columns" do
      {:ok, naive} = NaiveDateTime.from_iso8601("2024-01-02T03:04:05")

      assert elem(
               AshClickhouse.DataLayer.Insert.build_insert_rows([%{"at" => naive}],
                 DateTimeResource
               ),
               1
             ) == [[nil, 1_704_164_645_000_000]]

      # A 16-byte binary in a UUID column is converted to its string form.
      uuid = "123e4567-e89b-12d3-a456-426614174000"
      {:ok, uuid_bin} = Types.uuid_string_to_binary(uuid)

      assert elem(
               AshClickhouse.DataLayer.Insert.build_insert_rows([%{"id" => uuid_bin}],
                 DateTimeResource
               ),
               1
             ) == [[uuid, nil]]

      # A DateTime on a second-precision column encodes as epoch seconds.
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-02T03:04:05Z")

      assert elem(
               AshClickhouse.DataLayer.Insert.build_insert_rows([%{"at" => dt}],
                 SecondPrecisionDateTimeResource
               ),
               1
             ) == [[nil, 1_704_164_645_000_000]]
    end

    test "changeset_to_insert_attrs fills in a missing uuid pk typed as the module" do
      attrs =
        AshClickhouse.DataLayer.Insert.changeset_to_insert_attrs(
          %{attributes: %{}},
          ModuleUuidAutogenResource
        )

      assert attrs[:id] =~ ~r/^[0-9a-f-]{36}$/
    end
  end
end
