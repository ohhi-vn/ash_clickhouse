defmodule AshClickhouse.DataLayerCrudTest do
  @moduledoc """
  Unit tests for AshClickhouse.DataLayer CRUD, query building, and query
  transformation callbacks, exercised with an in-memory fake repo so no
  ClickHouse connection is required.
  """
  use ExUnit.Case, async: false

  import Ash.Query

  alias AshClickhouse.DataLayer
  alias AshClickhouse.Query

  # ── Fake domain ───────────────────────────────────────────────────────────

  defmodule FakeDomain do
    @moduledoc """
    Domain hosting the fake resources so Ash can resolve changesets/queries.
    """
    use Ash.Domain

    resources do
      resource(FakeResource)
      resource(TenantResource)
      resource(ContextTenantResource)
      resource(TransformResource)
    end
  end

  # ── Fake repo ───────────────────────────────────────────────────────────────

  defmodule FakeRepo do
    @moduledoc "Records every call and returns canned ClickHouse results."
    use Agent

    def start_link(opts \\ []), do: Agent.start_link(fn -> %{calls: []} end, opts)

    def record_call(pid, call),
      do: Agent.update(pid, &Map.update!(&1, :calls, fn c -> [call | c] end))

    def calls(pid), do: Agent.get(pid, & &1.calls)

    def query(sql, params, _opts) do
      if Process.whereis(__MODULE__) do
        record_call(__MODULE__, {:query, sql, params})
      end

      if Regex.match?(~r/SELECT\s+(COUNT|SUM|AVG|MIN|MAX)\(/i, sql) do
        {:ok,
         %ClickHouse.Result{
           raw: "",
           meta: %{},
           compressed: false,
           rows: [[1]],
           columns: ["result"]
         }}
      else
        {:ok,
         %ClickHouse.Result{
           raw: "",
           meta: %{},
           compressed: false,
           rows: [["id-1", "alice", "alice@example.com", 30]],
           columns: ["id", "name", "email", "age"]
         }}
      end
    end

    def query!(sql, params, _opts) do
      if Process.whereis(__MODULE__) do
        record_call(__MODULE__, {:query!, sql, params})
      end

      %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}
    end

    def insert_rows(_table, statement, rows, _opts) do
      if Process.whereis(__MODULE__) do
        record_call(__MODULE__, {:insert_rows, statement, length(rows)})
      end

      {:ok, :ok}
    end

    def database, do: "ash_clickhouse_test"
  end

  # ── Fake resources ──────────────────────────────────────────────────────────

  defmodule FakeResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerCrudTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("fake_users")
      repo(AshClickhouse.DataLayerCrudTest.FakeRepo)
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
      domain: AshClickhouse.DataLayerCrudTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("tenant_users")
      repo(AshClickhouse.DataLayerCrudTest.FakeRepo)
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

      update :update do
        accept([:name])
      end
    end
  end

  defmodule ContextTenantResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerCrudTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("ctx_tenant_users")
      repo(AshClickhouse.DataLayerCrudTest.FakeRepo)
    end

    multitenancy do
      strategy(:context)
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

  defmodule TransformResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerCrudTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("transform_users")
      repo(AshClickhouse.DataLayerCrudTest.FakeRepo)
      base_filter(status: "active")
      default_context(%{tenant: "org_1"})
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:status, :string)
      attribute(:name, :string)
    end

    actions do
      defaults([:read])
    end
  end

  setup do
    case FakeRepo.start_link(name: FakeRepo) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  # ── Query construction helpers ──────────────────────────────────────────────

  describe "resource_to_query/2 and return_query/2" do
    test "builds a data layer query for a resource" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert %Query{resource: FakeResource, table: "fake_users"} = q
      assert q.filters == []
    end

    test "return_query passes the query through" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert DataLayer.return_query(q, FakeResource) == {:ok, q}
    end

    test "data_layer_keyset_by_default? is false" do
      refute DataLayer.data_layer_keyset_by_default?()
    end
  end

  describe "query transformation callbacks" do
    test "filter/3 prepends an Ash.Filter expression" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      filter = %Ash.Filter{expression: %{operator: :>, left: %{name: :age}, right: %{value: 18}}}
      {:ok, q2} = DataLayer.filter(q, filter, FakeResource)
      assert length(q2.filters) == 1
    end

    test "sort/3 prepends sort clauses" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      {:ok, q2} = DataLayer.sort(q, [{:age, :desc}], FakeResource)
      assert q2.sorts == [{:age, :desc}]
    end

    test "limit/3 and offset/3 set values" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      {:ok, q2} = DataLayer.limit(q, 10, FakeResource)
      {:ok, q3} = DataLayer.offset(q2, 5, FakeResource)
      assert q3.limit == 10
      assert q3.offset == 5
    end

    test "select/3 sets the projection" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      {:ok, q2} = DataLayer.select(q, [:id, :name], FakeResource)
      assert q2.select == [:id, :name]
    end

    test "distinct/3 sets distinct columns and merges them into select" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      {:ok, q2} = DataLayer.distinct(q, [:name], FakeResource)
      assert q2.distinct == [:name]
      assert :name in q2.select
    end

    test "set_context/3 merges context" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      {:ok, q2} = DataLayer.set_context(FakeResource, q, %{tenant: "org_1"})
      assert q2.context[:tenant] == "org_1"
    end

    test "lock/3 is a no-op that returns the query" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert DataLayer.lock(q, :for_update, FakeResource) == {:ok, q}
    end

    test "combination_of/3 returns a QueryError" do
      q = DataLayer.resource_to_query(FakeResource, nil)

      assert {:error, %AshClickhouse.Error.QueryError{}} =
               DataLayer.combination_of(q, :union, FakeResource)
    end

    test "calculate/3 stores the calculation in context" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      calc = %{name: :full_name, module: nil, opts: []}
      {:ok, q2} = DataLayer.calculate(q, calc, FakeResource)
      assert q2.context.calculations == [calc]
    end

    test "add_aggregate/3 and add_aggregates/3 store aggregates in context" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      agg = %Ash.Query.Aggregate{kind: :count, name: :cnt, field: nil, resource: FakeResource}

      {:ok, q2} = DataLayer.add_aggregate(q, agg, FakeResource)
      assert q2.context.aggregates == [agg]

      {:ok, q3} = DataLayer.add_aggregates(q2, [agg, agg], FakeResource)
      assert length(q3.context.aggregates) == 3
    end
  end

  describe "set_tenant/3" do
    test "context strategy stores the tenant on the query" do
      q = DataLayer.resource_to_query(ContextTenantResource, nil)
      {:ok, q2} = DataLayer.set_tenant(ContextTenantResource, q, "org_1")
      assert q2.tenant == "org_1"
    end

    test "nil strategy stores the tenant on the query" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      {:ok, q2} = DataLayer.set_tenant(nil, q, "org_1")
      assert q2.tenant == "org_1"
    end

    test "attribute strategy adds a tenant equality filter" do
      q = DataLayer.resource_to_query(TenantResource, nil)
      {:ok, q2} = DataLayer.set_tenant(TenantResource, q, "org_1")
      assert length(q2.filters) == 1
    end
  end

  describe "transform_query/1" do
    test "applies base_filter and merges default_context" do
      q = TransformResource |> for_read(:read)
      transformed = DataLayer.transform_query(q)

      # base_filter adds a filter expression
      assert transformed.filter != nil
      # default_context is merged into the query context
      assert Map.get(transformed.context, :tenant) == "org_1"
    end
  end

  # ── CRUD through the data layer ─────────────────────────────────────────────

  describe "create/2" do
    test "inserts via the repo and returns an Ash record" do
      changeset =
        FakeResource
        |> Ash.Changeset.for_create(:create, %{name: "alice", email: "alice@example.com", age: 30})

      assert {:ok, %FakeResource{} = record} = DataLayer.create(FakeResource, changeset)
      assert record.name == "alice"
      refute is_nil(record.id)
    end
  end

  describe "update/2" do
    test "returns the record unchanged when there are no attributes to update" do
      record = struct(FakeResource, id: "id-1", name: "alice", email: "a@x", age: 30)

      changeset = Ash.Changeset.for_update(record, :update, %{})

      assert {:ok, %FakeResource{} = result} = DataLayer.update(FakeResource, changeset)
      assert result.name == "alice"
    end

    test "issues an ALTER TABLE UPDATE for changed attributes" do
      record = struct(FakeResource, id: "id-1", name: "alice", email: "a@x", age: 30)
      changeset = Ash.Changeset.for_update(record, :update, %{name: "bob"})

      assert {:ok, %FakeResource{} = result} = DataLayer.update(FakeResource, changeset)
      assert result.name == "bob"
    end
  end

  describe "destroy/2" do
    test "issues an ALTER TABLE DELETE and returns :ok" do
      record = struct(FakeResource, id: "id-1", name: "alice", email: "a@x", age: 30)
      changeset = Ash.Changeset.for_destroy(record, :destroy)

      assert :ok = DataLayer.destroy(FakeResource, changeset)
    end
  end

  # ── Query execution through the data layer ─────────────────────────────────

  describe "run_query/2" do
    test "decodes rows into Ash records" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      assert {:ok, [%FakeResource{} = record]} = DataLayer.run_query(q, FakeResource)
      assert record.name == "alice"
      assert record.age == 30
    end

    test "applies a filter before querying" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      filter = %Ash.Filter{expression: %{operator: :>, left: %{name: :age}, right: %{value: 18}}}
      {:ok, q2} = DataLayer.filter(q, filter, FakeResource)

      assert {:ok, [_]} = DataLayer.run_query(q2, FakeResource)

      assert Enum.any?(FakeRepo.calls(FakeRepo), fn
               {:query, sql, _} -> String.contains?(sql, "WHERE")
               _ -> false
             end)
    end
  end

  describe "run_aggregate_query/3" do
    test "returns a map of aggregate name => value" do
      q = DataLayer.resource_to_query(FakeResource, nil)

      aggregates = [
        %Ash.Query.Aggregate{kind: :count, name: :cnt, field: nil, resource: FakeResource},
        %Ash.Query.Aggregate{kind: :sum, name: :sum_age, field: :age, resource: FakeResource}
      ]

      {:ok, result} = DataLayer.run_aggregate_query(q, aggregates, FakeResource)
      assert is_number(result.cnt)
      assert is_number(result.sum_age)
    end
  end

  describe "update_query/4 and destroy_query/4" do
    test "update_query runs ALTER TABLE UPDATE then re-reads" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      record = struct(FakeResource, id: "id-1", name: "alice", email: "a@x", age: 30)
      changeset = Ash.Changeset.for_update(record, :update, %{name: "bob"})

      assert {:ok, [_]} = DataLayer.update_query(q, changeset, [], FakeResource)
    end

    test "destroy_query runs ALTER TABLE DELETE and returns :ok" do
      q = DataLayer.resource_to_query(FakeResource, nil)
      record = struct(FakeResource, id: "id-1", name: "alice", email: "a@x", age: 30)
      changeset = Ash.Changeset.for_destroy(record, :destroy)

      assert :ok = DataLayer.destroy_query(q, changeset, [], FakeResource)
    end
  end

  describe "bulk_create/3" do
    test "inserts rows via insert_rows and returns a stream of records" do
      changesets =
        for i <- 1..3 do
          FakeResource
          |> Ash.Changeset.for_create(:create, %{name: "u#{i}", email: "u#{i}@x", age: i})
        end

      assert {:ok, stream} = DataLayer.bulk_create(FakeResource, changesets, [])
      assert length(Enum.to_list(stream)) == 3

      assert Enum.any?(FakeRepo.calls(FakeRepo), fn
               {:insert_rows, statement, 3} -> String.contains?(statement, "INSERT INTO")
               _ -> false
             end)
    end
  end
end
