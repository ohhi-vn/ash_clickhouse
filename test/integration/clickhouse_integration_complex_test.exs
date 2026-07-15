defmodule AshClickhouse.ClickhouseIntegrationComplexTest do
  @moduledoc """
  Complex integration tests against a real ClickHouse instance.

  These build on the basic read path and exercise multi-clause filters, nested
  boolean expressions, aggregates with filters, pagination correctness, bulk
  inserts with many rows, and streaming consistency. Like the rest of the
  integration suite, the whole file is skipped when no ClickHouse instance is
  reachable.
  """

  use ExUnit.Case, async: false

  require Logger
  import Ash.Query

  alias AshClickhouse.ClickhouseContainer
  alias AshClickhouse.TestRepo
  alias AshClickhouse.TestResource

  @moduletag :integration

  @test_database "ash_clickhouse_test"

  setup_all do
    if direct_connect?() do
      url = direct_url()
      configure_repo(url)
      conn = start_repo_and_create_database(url)
      %{mode: :direct, conn: conn}
    else
      case AshClickhouse.Test.ContainerEngine.ensure_running() do
        :ok ->
          case ClickhouseContainer.start() do
            {:ok, container} ->
              url = ClickhouseContainer.url(container)
              configure_repo(url)
              conn = start_repo_and_create_database(url)
              %{mode: :container, conn: conn}

            {:error, reason} ->
              Logger.warning("Could not start ClickHouse container: #{inspect(reason)}")
              :ok
          end

        {:error, reason} ->
          Logger.warning("Container engine not available: #{inspect(reason)}")
          :ok
      end
    end
  end

  setup context do
    if Map.get(context, :conn) do
      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.test_users", [])
      TestRepo.query!(AshClickhouse.Migration.create_table_cql(TestResource), [])
      :ok
    else
      :ok
    end
  end

  defp direct_connect?,
    do: System.get_env("CLICKHOUSE_DIRECT") != nil or System.get_env("CLICKHOUSE_URL") != nil

  defp direct_url, do: System.get_env("CLICKHOUSE_URL") || "http://localhost:8123"

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

  # ── Complex filtering ────────────────────────────────────────────────────────

  describe "complex filters" do
    test "combined AND/OR filter", context do
      :ok = skip_unless_connected(context)

      insert_raw!([
        {Ash.UUID.generate(), "alice", "alice@example.com", 30},
        {Ash.UUID.generate(), "bob", "bob@example.com", 25},
        {Ash.UUID.generate(), "carol", "carol@example.com", 40}
      ])

      # age >= 30 OR (name == 'bob')
      users =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(age >= 30 or name == "bob")
        |> Ash.read!()

      assert length(users) == 3
    end

    test "nested filter with NOT", context do
      :ok = skip_unless_connected(context)

      insert_raw!([
        {Ash.UUID.generate(), "alice", "alice@example.com", 30},
        {Ash.UUID.generate(), "bob", "bob@example.com", 25}
      ])

      users =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(not (age < 18))
        |> Ash.read!()

      assert length(users) == 2
    end

    test "IN filter", context do
      :ok = skip_unless_connected(context)

      insert_raw!([
        {Ash.UUID.generate(), "alice", "alice@example.com", 30},
        {Ash.UUID.generate(), "bob", "bob@example.com", 25},
        {Ash.UUID.generate(), "carol", "carol@example.com", 40}
      ])

      users =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(name in ["alice", "carol"])
        |> Ash.read!()

      names = Enum.map(users, & &1.name) |> MapSet.new()
      assert names == MapSet.new(["alice", "carol"])
    end

    test "is_nil filter", context do
      :ok = skip_unless_connected(context)

      insert_raw!([
        {Ash.UUID.generate(), "alice", "alice@example.com", 30},
        {Ash.UUID.generate(), "bob", "bob@example.com", 25}
      ])

      users =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(not is_nil(email))
        |> Ash.read!()

      assert length(users) == 2
    end
  end

  # ── Aggregates with filters ────────────────────────────────────────────────────

  describe "aggregates with filters" do
    test "count respects the applied filter", context do
      :ok = skip_unless_connected(context)

      for i <- 1..10 do
        insert_raw!([{Ash.UUID.generate(), "u#{i}", "u#{i}@example.com", i}])
      end

      query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)

      ash_query =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(age >= 5)

      {:ok, dl_query} = AshClickhouse.DataLayer.filter(query, ash_query.filter, TestResource)

      aggregates = [
        %Ash.Query.Aggregate{kind: :count, name: :cnt, field: nil, resource: TestResource}
      ]

      {:ok, result} =
        AshClickhouse.DataLayer.run_aggregate_query(dl_query, aggregates, TestResource)

      assert result.cnt == 6
    end

    test "sum/avg/min/max over a filtered set", context do
      :ok = skip_unless_connected(context)

      for i <- 1..10 do
        insert_raw!([{Ash.UUID.generate(), "u#{i}", "u#{i}@example.com", i}])
      end

      query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)

      ash_query =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(age >= 5 and age <= 7)

      {:ok, dl_query} = AshClickhouse.DataLayer.filter(query, ash_query.filter, TestResource)

      aggregates = [
        %Ash.Query.Aggregate{kind: :sum, name: :sum_age, field: :age, resource: TestResource},
        %Ash.Query.Aggregate{kind: :avg, name: :avg_age, field: :age, resource: TestResource},
        %Ash.Query.Aggregate{kind: :min, name: :min_age, field: :age, resource: TestResource},
        %Ash.Query.Aggregate{kind: :max, name: :max_age, field: :age, resource: TestResource}
      ]

      {:ok, result} =
        AshClickhouse.DataLayer.run_aggregate_query(dl_query, aggregates, TestResource)

      assert result.sum_age == 18
      assert result.min_age == 5
      assert result.max_age == 7
      assert result.avg_age == 6.0
    end
  end

  # ── Pagination correctness ─────────────────────────────────────────────────────

  describe "pagination correctness" do
    test "limit/offset pages through a stable sort", context do
      :ok = skip_unless_connected(context)

      for i <- 1..20 do
        insert_raw!([{Ash.UUID.generate(), "u#{i}", "u#{i}@example.com", i}])
      end

      page1 =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(:age)
        |> Ash.Query.limit(5)
        |> Ash.read!()

      page2 =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.sort(:age)
        |> Ash.Query.limit(5)
        |> Ash.Query.offset(5)
        |> Ash.read!()

      all_ages = Enum.map(page1 ++ page2, & &1.age)
      assert all_ages == Enum.sort(all_ages)
      assert MapSet.disjoint?(MapSet.new(page1), MapSet.new(page2))
      assert length(page1) == 5
      assert length(page2) == 5
    end
  end

  # ── Bulk insert at scale ───────────────────────────────────────────────────────

  describe "bulk_create at scale" do
    test "inserts 100 rows and reads them back", context do
      :ok = skip_unless_connected(context)

      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.bulk_users", [])

      TestRepo.query!(
        AshClickhouse.Migration.create_table_cql(AshClickhouse.TestBulkResource),
        []
      )

      changesets =
        for i <- 1..100 do
          AshClickhouse.TestBulkResource
          |> Ash.Changeset.for_create(:create, %{
            name: "u#{i}",
            email: "u#{i}@example.com",
            age: i
          })
        end

      assert {:ok, stream} =
               AshClickhouse.DataLayer.bulk_create(AshClickhouse.TestBulkResource, changesets, [])

      assert length(Enum.to_list(stream)) == 100

      users = AshClickhouse.TestBulkResource |> Ash.read!()
      assert length(users) == 100
    after
      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.bulk_users", [])
    end
  end

  # ── Streaming vs non-streaming consistency ─────────────────────────────────────

  describe "streaming consistency" do
    test "stream and run_query return the same record set", context do
      :ok = skip_unless_connected(context)

      for i <- 1..15 do
        insert_raw!([{Ash.UUID.generate(), "s#{i}", "s#{i}@example.com", i}])
      end

      dl_query = AshClickhouse.DataLayer.resource_to_query(TestResource, AshClickhouse.TestDomain)

      {:ok, queried} = AshClickhouse.DataLayer.run_query(dl_query, TestResource)
      streamed = AshClickhouse.DataLayer.stream(dl_query, TestResource) |> Enum.to_list()

      queried_ids = queried |> Enum.map(& &1.id) |> MapSet.new()
      streamed_ids = streamed |> Enum.map(& &1.id) |> MapSet.new()

      assert queried_ids == streamed_ids
      assert length(streamed) == 15
    end
  end

  # ── Round-trip (create / read / update / destroy) ─────────────────────────────

  describe "round-trip via data layer" do
    test "create then read returns the inserted record", context do
      :ok = skip_unless_connected(context)

      changeset =
        TestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "alice",
          email: "alice@example.com",
          age: 30
        })

      assert {:ok, created} = AshClickhouse.DataLayer.create(TestResource, changeset)

      assert created.name == "alice"
      assert created.email == "alice@example.com"
      assert created.age == 30
      refute is_nil(created.id)
      refute is_nil(created.inserted_at)

      # Read it back through the data layer and confirm a full round-trip.
      assert [%AshClickhouse.TestResource{} = read] =
               TestResource
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^created.id)
               |> Ash.read!()

      assert read.id == created.id
      assert read.name == "alice"
      assert read.email == "alice@example.com"
      assert read.age == 30
    end

    test "update then read reflects the mutation", context do
      :ok = skip_unless_connected(context)

      {:ok, created} =
        TestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "bob",
          email: "bob@example.com",
          age: 25
        })
        |> then(&AshClickhouse.DataLayer.create(TestResource, &1))

      # Build an update changeset and apply it through the data layer.
      update_changeset =
        created
        |> Ash.Changeset.for_update(:update, %{name: "bob_updated", age: 26})

      assert {:ok, updated} =
               AshClickhouse.DataLayer.update(TestResource, update_changeset)

      assert updated.name == "bob_updated"
      assert updated.age == 26

      assert [read] =
               TestResource
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^created.id)
               |> Ash.read!()

      assert read.name == "bob_updated"
      assert read.age == 26
      assert read.email == "bob@example.com"
    end

    test "destroy then read returns no record", context do
      :ok = skip_unless_connected(context)

      {:ok, created} =
        TestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "carol",
          email: "carol@example.com",
          age: 40
        })
        |> then(&AshClickhouse.DataLayer.create(TestResource, &1))

      destroy_changeset = Ash.Changeset.for_destroy(created, :destroy)

      assert :ok = AshClickhouse.DataLayer.destroy(TestResource, destroy_changeset)

      assert [] =
               TestResource
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^created.id)
               |> Ash.read!()
    end

    test "multiple creates then filtered read round-trips each row", context do
      :ok = skip_unless_connected(context)

      created =
        for i <- 1..10 do
          {:ok, rec} =
            TestResource
            |> Ash.Changeset.for_create(:create, %{
              name: "rt_#{i}",
              email: "rt_#{i}@example.com",
              age: i * 10
            })
            |> then(&AshClickhouse.DataLayer.create(TestResource, &1))

          rec
        end

      ids = MapSet.new(created, & &1.id)
      assert MapSet.size(ids) == 10

      adults =
        TestResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(age >= 50)
        |> Ash.read!()

      assert length(adults) == 5
      assert Enum.all?(adults, &MapSet.member?(ids, &1.id))
      assert Enum.all?(adults, &(&1.age >= 50))
    end
  end

  describe "round-trip via bulk_create" do
    test "bulk insert then read/filter/update/destroy cycle", context do
      :ok = skip_unless_connected(context)

      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.bulk_users", [])
      TestRepo.query!(AshClickhouse.Migration.create_table_cql(AshClickhouse.TestBulkResource), [])

      changesets =
        for i <- 1..20 do
          AshClickhouse.TestBulkResource
          |> Ash.Changeset.for_create(:create, %{
            name: "bu_#{i}",
            email: "bu_#{i}@example.com",
            age: i
          })
        end

      assert {:ok, _stream} =
               AshClickhouse.DataLayer.bulk_create(AshClickhouse.TestBulkResource, changesets, [])

      # Read all back.
      assert 20 = AshClickhouse.TestBulkResource |> Ash.read!() |> length()

      # Filter round-trip.
      even =
        AshClickhouse.TestBulkResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(age > 10)
        |> Ash.read!()

      assert length(even) == 10
      assert Enum.all?(even, &(&1.age > 10))

      # Update a subset via the data layer's update_query.
      target = hd(even)

      ash_query =
        AshClickhouse.TestBulkResource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^target.id)

      dl_query =
        AshClickhouse.DataLayer.resource_to_query(AshClickhouse.TestBulkResource, AshClickhouse.TestDomain)

      {:ok, dl_query} =
        AshClickhouse.DataLayer.filter(dl_query, ash_query.filter, AshClickhouse.TestBulkResource)

      changeset =
        target
        |> Ash.Changeset.for_update(:update, %{name: "renamed"})

      assert {:ok, [_]} =
               AshClickhouse.DataLayer.update_query(dl_query, changeset, [], AshClickhouse.TestBulkResource)

      assert [%AshClickhouse.TestBulkResource{name: "renamed"}] =
               AshClickhouse.TestBulkResource
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^target.id)
               |> Ash.read!()

      # Destroy the subset via the data layer's destroy_query.
      assert :ok =
               AshClickhouse.DataLayer.destroy_query(dl_query, changeset, [], AshClickhouse.TestBulkResource)

      assert [] =
               AshClickhouse.TestBulkResource
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(id == ^target.id)
               |> Ash.read!()
    after
      TestRepo.query!("DROP TABLE IF EXISTS #{@test_database}.bulk_users", [])
    end
  end

  # ── Error handling ─────────────────────────────────────────────────────────────

  describe "error handling" do
    test "a malformed query returns an error tuple", context do
      :ok = skip_unless_connected(context)
      assert {:error, _} = TestRepo.query("SELECT * FROM nonexistent_table_xyz", [])
    end
  end
end
