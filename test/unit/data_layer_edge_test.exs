defmodule AshClickhouse.DataLayerEdgeTest do
  @moduledoc """
  Edge-case and complex unit tests for `AshClickhouse.DataLayer`, exercised with an
  in-memory fake repo so no ClickHouse connection is required.

  These cover the branches that the happy-path CRUD tests skip: empty result
  sets, error propagation, aggregate default values, bulk_create edge inputs,
  tenant handling, and in-memory calculation/aggregate attachment.
  """
  use ExUnit.Case, async: false

  import Ash.Query

  alias AshClickhouse.DataLayer
  alias AshClickhouse.Query

  # ── Fake repo ────────────────────────────────────────────────────────────────

  defmodule FakeRepo do
    @moduledoc "Returns canned results selected by `set_mode/2`."
    use Agent

    # Start unlinked so the agent survives the test process exiting between
    # tests (a linked Agent.start_link would be killed when each test's
    # process terminates, leaving a dead named process for the next setup).
    def start(opts \\ []),
      do: Agent.start(fn -> %{calls: [], mode: :rows} end, opts)

    def set_mode(pid, mode), do: Agent.update(pid, &Map.put(&1, :mode, mode))
    def reset(pid), do: Agent.update(pid, fn _ -> %{calls: [], mode: :rows} end)
    def calls(pid), do: Agent.get(pid, & &1.calls)
    def insert_calls(pid), do: Agent.get(pid, &for({:insert_rows, n} <- &1.calls, do: n))

    def query(sql, params, _opts) do
      record({:query, sql, params})

      mode = Agent.get(__MODULE__, & &1.mode)

      case mode do
        :rows ->
          {:ok,
           %ClickHouse.Result{
             raw: "",
             meta: %{},
             compressed: false,
             rows: [["id-1", "alice", "alice@example.com", 30]],
             columns: ["id", "name", "email", "age"]
           }}

        :empty ->
          {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}

        :non_result ->
          # A non-Result :ok value hits the `{:ok, _}` fallback clause and
          # yields an empty list (rather than enumerating a non-list `rows`).
          {:ok, :not_a_result}

        :aggregate ->
          {:ok,
           %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [[42]], columns: ["r"]}}

        :aggregate_empty ->
          {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}

        :error ->
          {:error, %ClickHouse.QueryError{message: "bad sql"}}
      end
    end

    def query!(sql, params, _opts) do
      record({:query, sql, params})
      %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}
    end

    def insert_rows(_table, _statement, rows, _opts) do
      record({:insert_rows, length(rows)})
      {:ok, :ok}
    end

    def database, do: "ash_clickhouse_test"

    defp record(call) do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, &Map.update!(&1, :calls, fn c -> [call | c] end))
      end
    end
  end

  # ── Fake domain (must be defined before the resources that reference it) ──

  defmodule FakeDomain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource(FakeResource)
      resource(TenantResource)
      resource(TenantNoAttrResource)
    end
  end

  # ── Fake resources ──────────────────────────────────────────────────────────────

  defmodule FakeResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerEdgeTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("edge_users")
      repo(AshClickhouse.DataLayerEdgeTest.FakeRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
      attribute(:age, :integer)
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([:name, :email, :age])
      end

      update :update do
        accept([:name, :email, :age])
      end
    end
  end

  defmodule TenantResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerEdgeTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("edge_tenant_users")
      repo(AshClickhouse.DataLayerEdgeTest.FakeRepo)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :string)
      attribute(:name, :string)
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([:org_id, :name])
      end
    end
  end

  defmodule TenantNoAttrResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerEdgeTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("edge_tenant_no_attr")
      repo(AshClickhouse.DataLayerEdgeTest.FakeRepo)
    end

    # Attribute strategy declared but no multitenancy attribute configured.
    multitenancy do
      strategy(:attribute)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([:name])
      end
    end
  end

  # A calculation module used to exercise in-memory calculation attachment.
  defmodule AddOneCalc do
    def calculate(records, _opts), do: Enum.map(records, fn r -> r.age + 1 end)
  end

  setup do
    case FakeRepo.start(name: FakeRepo) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    FakeRepo.reset(FakeRepo)
    :ok
  end

  # ── run_query/2 edge cases ─────────────────────────────────────────────────────

  describe "run_query/2 result handling" do
    test "decodes rows into Ash records" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert {:ok, [%FakeResource{} = r]} = DataLayer.run_query(q, FakeResource)
      assert r.name == "alice"
      assert r.age == 30
    end

    test "an empty result set returns an empty list" do
      FakeRepo.set_mode(FakeRepo, :empty)
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert {:ok, []} = DataLayer.run_query(q, FakeResource)
    end

    test "a non-row :ok result returns an empty list" do
      FakeRepo.set_mode(FakeRepo, :non_result)
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert {:ok, []} = DataLayer.run_query(q, FakeResource)
    end

    test "a repo error is wrapped and returned as an error tuple" do
      FakeRepo.set_mode(FakeRepo, :error)
      q = DataLayer.resource_to_query(FakeResource, nil)

      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               DataLayer.run_query(q, FakeResource)
    end
  end

  # ── run_aggregate_query/3 edge cases ──────────────────────────────────────────

  describe "run_aggregate_query/3" do
    test "an empty aggregate list returns an empty map" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert {:ok, %{}} = DataLayer.run_aggregate_query(q, [], FakeResource)
    end

    test "decodes aggregate values from a result row" do
      FakeRepo.set_mode(FakeRepo, :aggregate)
      q = DataLayer.resource_to_query(FakeResource, nil)

      aggregates = [
        %Ash.Query.Aggregate{kind: :count, name: :cnt, field: nil, resource: FakeResource},
        %Ash.Query.Aggregate{kind: :sum, name: :sum_age, field: :age, resource: FakeResource}
      ]

      {:ok, result} = DataLayer.run_aggregate_query(q, aggregates, FakeResource)
      assert result.cnt == 42
      assert result.sum_age == 42
    end

    test "uses the aggregate default_value when no rows are returned" do
      FakeRepo.set_mode(FakeRepo, :aggregate_empty)
      q = DataLayer.resource_to_query(FakeResource, nil)

      aggregates = [
        %Ash.Query.Aggregate{
          kind: :sum,
          name: :sum_age,
          field: :age,
          resource: FakeResource,
          default_value: 0
        }
      ]

      {:ok, result} = DataLayer.run_aggregate_query(q, aggregates, FakeResource)
      assert result.sum_age == 0
    end

    test "an unsupported aggregate kind returns an error" do
      q = DataLayer.resource_to_query(FakeResource, nil)

      aggregates = [
        %Ash.Query.Aggregate{kind: :median, name: :m, field: :age, resource: FakeResource}
      ]

      assert {:error, _} = DataLayer.run_aggregate_query(q, aggregates, FakeResource)
    end
  end

  # ── bulk_create/3 edge cases ───────────────────────────────────────────────────

  describe "bulk_create/3" do
    test "an empty changeset list returns an empty stream" do
      assert {:ok, stream} = DataLayer.bulk_create(FakeResource, [], [])
      assert Enum.to_list(stream) == []
    end

    test "return_records?: false returns an empty list rather than a stream" do
      changesets =
        for i <- 1..2 do
          FakeResource
          |> Ash.Changeset.for_create(:create, %{name: "u#{i}", email: "u#{i}@x", age: i})
        end

      assert {:ok, []} = DataLayer.bulk_create(FakeResource, changesets, return_records?: false)
    end

    test "respects a small batch_size by chunking insert_rows calls" do
      changesets =
        for i <- 1..5 do
          FakeResource
          |> Ash.Changeset.for_create(:create, %{name: "u#{i}", email: "u#{i}@x", age: i})
        end

      assert {:ok, stream} = DataLayer.bulk_create(FakeResource, changesets, batch_size: 2)
      assert length(Enum.to_list(stream)) == 5

      # 5 rows in batches of 2 => [2, 2, 1] => 3 insert_rows calls.
      # The fake repo prepends calls, so the recorded order is reversed.
      assert FakeRepo.insert_calls(FakeRepo) == [1, 2, 2]
    end
  end

  # ── set_tenant/3 edge cases ───────────────────────────────────────────────────

  describe "set_tenant/3" do
    test "attribute strategy adds an equality filter for the tenant" do
      q = DataLayer.resource_to_query(TenantResource, nil)
      {:ok, q2} = DataLayer.set_tenant(TenantResource, q, "org_1")
      assert length(q2.filters) == 1
    end

    test "attribute strategy with no configured attribute stores the tenant" do
      q = DataLayer.resource_to_query(TenantNoAttrResource, nil)
      {:ok, q2} = DataLayer.set_tenant(TenantNoAttrResource, q, "org_1")
      assert q2.tenant == "org_1"
      assert q2.filters == []
    end
  end

  # ── filter/3 edge cases ───────────────────────────────────────────────────────

  describe "filter/3" do
    test "wraps a raw (non-Ash.Filter) term as a filter expression" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      raw = %{operator: :>, left: %{name: :age}, right: %{value: 18}}
      {:ok, q2} = DataLayer.filter(q, raw, FakeResource)
      assert q2.filters == [raw]
    end

    test "prepends an Ash.Filter expression" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      f = %Ash.Filter{expression: %{operator: :>, left: %{name: :age}, right: %{value: 18}}}
      {:ok, q2} = DataLayer.filter(q, f, FakeResource)
      assert length(q2.filters) == 1
    end
  end

  # ── in-memory calculations and aggregates ──────────────────────────────────────

  describe "in-memory calculations (apply_calculations)" do
    test "a module calculation is attached to each record" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      calc = %{name: :age_plus_one, module: AddOneCalc, opts: []}
      {:ok, q2} = DataLayer.calculate(q, calc, FakeResource)

      FakeRepo.set_mode(FakeRepo, :rows)
      {:ok, [record]} = DataLayer.run_query(q2, FakeResource)

      # `calculate/2` returns a list, so the attached value is `[age + 1]`.
      assert Map.get(record, :age_plus_one) == [31]
    end

    test "an unsupported calculation is ignored (record unchanged)" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      calc = %{name: :nope, module: nil, opts: []}
      {:ok, q2} = DataLayer.calculate(q, calc, FakeResource)

      {:ok, [record]} = DataLayer.run_query(q2, FakeResource)
      refute Map.has_key?(record, :nope)
    end
  end

  describe "aggregate attachment in run_query/2" do
    test "per-record aggregates are merged into the record's aggregates map" do
      FakeRepo.set_mode(FakeRepo, :aggregate)
      q = DataLayer.resource_to_query(FakeResource, nil)

      agg = %Ash.Query.Aggregate{
        kind: :count,
        name: :cnt,
        field: nil,
        resource: FakeResource,
        relationship_path: []
      }

      {:ok, q2} = DataLayer.add_aggregate(q, agg, FakeResource)

      {:ok, [record]} = DataLayer.run_query(q2, FakeResource)
      assert Map.get(record.aggregates, :cnt) == 42
    end
  end

  # ── transform_query/1 edge cases ──────────────────────────────────────────────

  describe "transform_query/1" do
    test "leaves a query unchanged when there is no base_filter" do
      q = FakeResource |> for_read(:read)
      transformed = DataLayer.transform_query(q)
      assert transformed.filter == q.filter
    end
  end

  # ── update/2 no-op path ───────────────────────────────────────────────────────

  describe "update/2" do
    test "returns the record unchanged when there are no attributes to update" do
      record = struct(FakeResource, id: "id-1", name: "alice", email: "a@x", age: 30)
      changeset = Ash.Changeset.for_update(record, :update, %{})
      assert {:ok, %FakeResource{} = result} = DataLayer.update(FakeResource, changeset)
      assert result.name == "alice"
    end
  end
end
