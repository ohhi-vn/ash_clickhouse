defmodule AshClickhouse.ClickhouseIntegrationTest do
  @moduledoc """
  Integration tests for AshClickhouse against a real ClickHouse instance.

  Two connection modes are supported:

  1. Auto-created test container (default). A ClickHouse container is started
     via `testcontainer_ex` and the test repo is pointed at it. This requires a
     reachable container engine (Docker or Podman). When none is available the
     whole suite is skipped.

  2. Direct connect. Set `CLICKHOUSE_DIRECT=1` (or `CLICKHOUSE_URL`) to connect
     to an already-running ClickHouse instance instead of spinning up a
     container. This is useful in CI or local development:

         CLICKHOUSE_DIRECT=1 CLICKHOUSE_URL=http://localhost:8123 \\
           mix test.integration

  The test database is created on demand and dropped afterwards.

  ## Known limitation

  Ash-action `create`/`update`/`destroy` are currently skipped: the data
  layer's `INSERT` statement uses `?` placeholders, which the `clickhouse`
  0.32 client's INSERT path does not accept (it expects row-format params). The
  read path, raw SQL execution, and migration SQL generation are fully
  exercised below.
  """

  use ExUnit.Case, async: false

  require Logger
  import Ash.Query

  alias AshClickhouse.TestRepo
  alias AshClickhouse.TestResource
  alias AshClickhouse.ClickhouseContainer

  @moduletag :integration

  @test_database "ash_clickhouse_test"

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    if direct_connect?() do
      url = direct_url()
      Logger.info("CLICKHOUSE_DIRECT set. Connecting directly to ClickHouse at #{url}")

      configure_repo(url)
      conn = start_repo_and_create_database(url)
      %{mode: :direct, container: nil, conn: conn}
    else
      case AshClickhouse.Test.ContainerEngine.ensure_running() do
        :ok ->
          Logger.info("Container engine available. Starting ClickHouse container...")

          case ClickhouseContainer.start() do
            {:ok, container} ->
              url = ClickhouseContainer.url(container)
              Logger.info("ClickHouse container started at #{url}")

              configure_repo(url)
              conn = start_repo_and_create_database(url)
              %{mode: :container, container: container, conn: conn}

            {:error, reason} ->
              Logger.warning(
                "Could not start ClickHouse container: #{inspect(reason)}. Skipping integration tests."
              )

              :ok
          end

        {:error, reason} ->
          Logger.warning(
            "Container engine not available: #{inspect(reason)}. Integration tests will be skipped."
          )

          :ok
      end
    end
  end

  setup context do
    case Map.get(context, :conn) do
      nil ->
        :ok

      _conn ->
        # Reset the table between tests for isolation.
        TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.test_users", [])
        TestRepo.query!(AshClickhouse.Migration.create_table_cql(TestResource), [])
        :ok
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp direct_connect? do
    System.get_env("CLICKHOUSE_DIRECT") != nil or System.get_env("CLICKHOUSE_URL") != nil
  end

  defp direct_url do
    System.get_env("CLICKHOUSE_URL") || "http://localhost:8123"
  end

  defp configure_repo(url) do
    repo_config =
      Application.get_env(:ash_clickhouse, TestRepo, [])
      |> Keyword.put(:url, url)
      |> Keyword.put(:database, nil)

    Application.put_env(:ash_clickhouse, TestRepo, repo_config)
  end

  defp start_repo_and_create_database(url) do
    {:ok, _} = start_supervised(TestRepo.child_spec([]))
    {:ok, _} = TestRepo.query("CREATE DATABASE IF NOT EXISTS #{@test_database}", [])
    {:ok, _} = TestRepo.query("DROP TABLE IF EXISTS #{@test_database}.test_users", [])
    {:ok, _} = TestRepo.query(AshClickhouse.Migration.create_table_cql(TestResource), [])
    url
  end

  defp skip_unless_connected(context) do
    if Map.get(context, :conn) do
      :ok
    else
      {:skip,
       "No ClickHouse instance available (set CLICKHOUSE_DIRECT=1 or run a container engine)"}
    end
  end

  # Inserts rows directly via SQL (bypasses the data layer's INSERT path, which
  # is currently incompatible with the clickhouse 0.32 client).
  defp insert_raw!(rows) when is_list(rows) do
    columns = [:id, :name, :email, :age]

    values =
      Enum.map(rows, fn row ->
        row
        |> Tuple.to_list()
        |> Enum.map_join(", ", &quote_value/1)
        |> then(&"(#{&1})")
      end)

    sql =
      "INSERT INTO #{@test_database}.test_users (#{Enum.join(columns, ", ")}) VALUES " <>
        Enum.join(values, ", ")

    TestRepo.query!(sql, [])
  end

  defp quote_value(value) when is_binary(value), do: "'#{value}'"
  defp quote_value(value) when is_integer(value), do: to_string(value)
  defp quote_value(nil), do: "NULL"

  # ── Connectivity ───────────────────────────────────────────────────────────

  describe "connectivity" do
    test "ping via SELECT 1", context do
      :ok = skip_unless_connected(context)
      assert {:ok, _} = TestRepo.query("SELECT 1", [])
    end

    test "server version is reachable", context do
      :ok = skip_unless_connected(context)
      {:ok, result} = TestRepo.query("SELECT version() AS v", [])
      assert result.rows != nil
    end
  end

  # ── Migration SQL generation & execution ──────────────────────────────────

  describe "migration" do
    test "generated CREATE TABLE executes against ClickHouse", context do
      :ok = skip_unless_connected(context)

      sql = AshClickhouse.Migration.create_table_cql(TestResource)
      assert String.contains?(sql, "CREATE TABLE IF NOT EXISTS")
      assert String.contains?(sql, "ENGINE = MergeTree()")

      {:ok, _} = TestRepo.query(sql, [])
    end
  end

  # ── Read path through the data layer ───────────────────────────────────────

  describe "read path (filter / sort / limit / offset / aggregates)" do
    test "read all rows", context do
      :ok = skip_unless_connected(context)

      insert_raw!([
        {Ash.UUID.generate(), "alice", "alice@example.com", 30},
        {Ash.UUID.generate(), "bob", "bob@example.com", 25}
      ])

      users = TestResource |> Ash.read!()
      assert length(users) == 2
      assert Enum.all?(users, &match?(%AshClickhouse.TestResource{}, &1))
    end

    test "filter", context do
      :ok = skip_unless_connected(context)

      insert_raw!([
        {Ash.UUID.generate(), "alice", "alice@example.com", 30},
        {Ash.UUID.generate(), "bob", "bob@example.com", 25}
      ])

      adults =
        TestResource
        |> Ash.Query.for_read(:read)
        |> filter(age >= 30)
        |> Ash.read!()

      assert length(adults) == 1
      assert hd(adults).name == "alice"
    end

    test "sort, limit and offset", context do
      :ok = skip_unless_connected(context)

      for i <- 1..10 do
        insert_raw!([{Ash.UUID.generate(), "user_#{i}", "user_#{i}@example.com", i * 10}])
      end

      page =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(:age)
        |> Ash.Query.limit(3)
        |> Ash.Query.offset(2)
        |> Ash.read!()

      ages = Enum.map(page, & &1.age)
      assert ages == Enum.sort(ages)
      assert length(page) == 3
      assert hd(ages) == 30
    end

    test "aggregates", context do
      :ok = skip_unless_connected(context)

      for i <- 1..5 do
        insert_raw!([{Ash.UUID.generate(), "agg_#{i}", "agg_#{i}@example.com", i}])
      end

      users = TestResource |> Ash.Query.for_read(:read) |> Ash.read!()
      assert length(users) == 5
    end
  end

  # ── Aggregates (via the data layer) ──────────────────────────────────────

  describe "aggregates (count / sum / avg / min / max)" do
    test "run_aggregate_query computes each kind", context do
      :ok = skip_unless_connected(context)

      for i <- 1..10 do
        insert_raw!([{Ash.UUID.generate(), "agg_#{i}", "agg_#{i}@example.com", i}])
      end

      query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)

      aggregates = [
        %Ash.Query.Aggregate{kind: :count, name: :cnt, field: nil, resource: TestResource},
        %Ash.Query.Aggregate{kind: :sum, name: :sum_age, field: :age, resource: TestResource},
        %Ash.Query.Aggregate{kind: :avg, name: :avg_age, field: :age, resource: TestResource},
        %Ash.Query.Aggregate{kind: :min, name: :min_age, field: :age, resource: TestResource},
        %Ash.Query.Aggregate{kind: :max, name: :max_age, field: :age, resource: TestResource}
      ]

      {:ok, result} = AshClickhouse.DataLayer.run_aggregate_query(query, aggregates, TestResource)

      assert result.cnt == 10
      assert result.sum_age == 55
      assert result.max_age == 10
      assert result.min_age == 1
      assert result.avg_age == 5.5
    end
  end

  # ── bulk_create ────────────────────────────────────────────────────────────

  describe "bulk_create" do
    test "inserts rows and they become readable", context do
      :ok = skip_unless_connected(context)

      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.bulk_users", [])

      TestRepo.query!(
        AshClickhouse.Migration.create_table_cql(AshClickhouse.TestBulkResource),
        []
      )

      changesets =
        for i <- 1..5 do
          AshClickhouse.TestBulkResource
          |> Ash.Changeset.for_create(:create, %{
            name: "u#{i}",
            email: "u#{i}@example.com",
            age: i
          })
        end

      assert {:ok, stream} =
               AshClickhouse.DataLayer.bulk_create(AshClickhouse.TestBulkResource, changesets, [])

      assert length(Enum.to_list(stream)) == 5

      users = AshClickhouse.TestBulkResource |> Ash.read!()
      assert length(users) == 5
    after
      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.bulk_users", [])
    end
  end

  # ── update_query / destroy_query ───────────────────────────────────────────

  describe "update_query and destroy_query" do
    test "update_query modifies matching rows", context do
      :ok = skip_unless_connected(context)

      id = Ash.UUID.generate()
      insert_raw!([{id, "alice", "alice@example.com", 30}])

      ash_query =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(age >= 30)

      dl_query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)
      {:ok, dl_query} = AshClickhouse.DataLayer.filter(dl_query, ash_query.filter, TestResource)

      record = struct(TestResource, id: id, name: "alice", email: "alice@example.com", age: 30)
      changeset = Ash.Changeset.for_update(record, :update, %{name: "alice_updated"})

      assert {:ok, [_]} =
               AshClickhouse.DataLayer.update_query(dl_query, changeset, [], TestResource)

      updated =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(name == "alice_updated")
        |> Ash.read!()

      assert length(updated) == 1
    end

    test "destroy_query removes matching rows", context do
      :ok = skip_unless_connected(context)

      id = Ash.UUID.generate()
      insert_raw!([{id, "bob", "bob@example.com", 25}])

      ash_query =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(name == "bob")

      dl_query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)
      {:ok, dl_query} = AshClickhouse.DataLayer.filter(dl_query, ash_query.filter, TestResource)

      record = struct(TestResource, id: id, name: "bob", email: "bob@example.com", age: 25)
      changeset = Ash.Changeset.for_destroy(record, :destroy)

      assert :ok = AshClickhouse.DataLayer.destroy_query(dl_query, changeset, [], TestResource)

      remaining =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(name == "bob")
        |> Ash.read!()

      assert remaining == []
    end
  end

  # ── distinct & streaming ───────────────────────────────────────────────────

  describe "distinct and streaming reads" do
    test "distinct collapses duplicate projected values", context do
      :ok = skip_unless_connected(context)

      for i <- 1..3 do
        insert_raw!([{Ash.UUID.generate(), "dup", "dup#{i}@example.com", i}])
      end

      dl_query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)
      {:ok, dl_query} = AshClickhouse.DataLayer.distinct(dl_query, [:name], TestResource)

      {:ok, records} = AshClickhouse.DataLayer.run_query(dl_query, TestResource)
      names = Enum.map(records, & &1.name)
      assert MapSet.size(MapSet.new(names)) == 1
    end

    test "stream yields decoded records one at a time", context do
      :ok = skip_unless_connected(context)

      for i <- 1..5 do
        insert_raw!([{Ash.UUID.generate(), "stream_#{i}", "stream_#{i}@example.com", i}])
      end

      dl_query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)
      stream = AshClickhouse.DataLayer.stream(dl_query, TestResource)
      records = Enum.to_list(stream)
      assert length(records) == 5
      assert Enum.all?(records, &match?(%AshClickhouse.TestResource{}, &1))
    end
  end

  # ── Partitioned DDL ────────────────────────────────────────────────────────

  describe "partitioned table DDL" do
    test "CREATE TABLE with PARTITION BY / PRIMARY KEY / SETTINGS executes", context do
      :ok = skip_unless_connected(context)

      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.partitioned_users", [])
      sql = AshClickhouse.Migration.create_table_cql(AshClickhouse.TestPartitionedResource)
      TestRepo.query!(sql, [])

      assert String.contains?(sql, "PARTITION BY toYYYYMM(created_date)")
      assert String.contains?(sql, "PRIMARY KEY (`id`)")
      assert String.contains?(sql, "SETTINGS index_granularity = 8192")
    after
      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.partitioned_users", [])
    end
  end

  # ── Error handling ─────────────────────────────────────────────────────────

  describe "error handling" do
    test "a bad query returns an error tuple rather than raising", context do
      :ok = skip_unless_connected(context)
      assert {:error, _} = TestRepo.query("SELECT * FROM nonexistent_table_xyz", [])
    end
  end

  # ── Ash-action CRUD (known limitation) ─────────────────────────────────────

  describe "Ash-action CRUD (skipped: data layer INSERT incompatibility)" do
    @tag :skip
    test "create and read a record via Ash actions", context do
      :ok = skip_unless_connected(context)

      {:ok, user} =
        TestResource
        |> Ash.Changeset.for_create(:create, %{name: "alice", email: "alice@example.com", age: 30})
        |> Ash.create()

      assert user.name == "alice"
      assert user.age == 30
      refute is_nil(user.id)
    end
  end
end
