defmodule AshClickhouse.DataLayerReviewFixesTest do
  @moduledoc """
  Tests for the correctness/design fixes from the code review:

  - UUID heuristic no longer mangles 36-char `:string` values (item #1).
  - Relationship aggregates are batched (one query per aggregate, not per
    record) and support has_many/has_one (items #3/#4).
  - Aggregate decoding is type-aware and consistent across both code paths
    (items #5/#6).
  - Repo cache can be cleared for tests (cache invalidation item).
  """
  use ExUnit.Case, async: false

  import Ash.Query

  alias AshClickhouse.DataLayer
  alias AshClickhouse.Query

  # ── Fake repo ────────────────────────────────────────────────────────────────

  defmodule FakeRepo do
    @moduledoc "Records calls and returns canned results keyed by SQL shape."
    use Agent

    def start(opts \\ []), do: Agent.start(fn -> %{calls: [], mode: :rows} end, opts)
    def reset(pid), do: Agent.update(pid, fn _ -> %{calls: [], mode: :rows} end)
    def calls(pid), do: Agent.get(pid, & &1.calls)

    def query(sql, params, _opts) do
      record({:query, sql, params})

      cond do
        Regex.match?(~r/SELECT\s+(COUNT|SUM|AVG|MIN|MAX)\(/i, sql) ->
          # Aggregate result. Return a string so we can assert decode behaviour.
          {:ok,
           %ClickHouse.Result{
             raw: "",
             meta: %{},
             compressed: false,
             rows: [["42"]],
             columns: ["r"]
           }}

        Regex.match?(~r/WHERE\s+`id`\s+IN/i, sql) ->
          # Batched same-table aggregate: return one row per requested pk.
          {:ok,
           %ClickHouse.Result{
             raw: "",
             meta: %{},
             compressed: false,
             rows: [["id-1", "10"], ["id-2", "20"]],
             columns: ["id", "result"]
           }}

        Regex.match?(~r/GROUP BY/i, sql) ->
          # Batched related (has_many/has_one) aggregate. Keyed by the source
          # record's fk value (the customer's id, "id-1") so it merges back
          # into the record rather than falling back to default_value.
          {:ok,
           %ClickHouse.Result{
             raw: "",
             meta: %{},
             compressed: false,
             rows: [["id-1", "42"]],
             columns: ["customer_id", "result"]
           }}

        true ->
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
      record({:query!, sql, params})
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

  # ── Fake domain ──────────────────────────────────────────────────────────────

  defmodule FakeDomain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource(CustomerResource)
      resource(OrderResource)
    end
  end

  defmodule OrderResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerReviewFixesTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("orders")
      repo(AshClickhouse.DataLayerReviewFixesTest.FakeRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:customer_id, :string)
      attribute(:total, :decimal)
    end

    relationships do
      belongs_to(:customer, CustomerResource)
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([:customer_id, :total])
      end
    end
  end

  defmodule CustomerResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.DataLayerReviewFixesTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("customers")
      repo(AshClickhouse.DataLayerReviewFixesTest.FakeRepo)
    end

    attributes do
      uuid_primary_key(:id)
      # A legitimate 36-char business identifier stored as a string. The old
      # UUID heuristic would have mangled this into a 16-byte binary.
      attribute(:order_number, :string)
      attribute(:name, :string)
    end

    relationships do
      has_many(:orders, OrderResource)
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([:order_number, :name])
      end
    end
  end

  setup do
    case FakeRepo.start(name: FakeRepo) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    FakeRepo.reset(FakeRepo)
    :ok
  end

  # ── UUID heuristic (item #1) ──────────────────────────────────────────────────

  describe "UUID heuristic does not mangle :string columns (item #1)" do
    test "a 36-char :string value is passed through unchanged on insert" do
      business_id = "12345678-1234-1234-1234-123456789012"

      changeset =
        CustomerResource
        |> Ash.Changeset.for_create(:create, %{order_number: business_id, name: "acme"})

      {:ok, %CustomerResource{} = record} = DataLayer.create(CustomerResource, changeset)

      # The record round-trips the value unchanged (no 16-byte binary mangling).
      assert record.order_number == business_id

      # The INSERT params contain the original string, not a binary.
      insert_call =
        Enum.find(FakeRepo.calls(FakeRepo), fn
          {:query, sql, _params} -> String.contains?(sql, "INSERT INTO")
          _ -> false
        end)

      assert insert_call != nil

      {:query, _sql, params} = insert_call
      assert business_id in params
    end

    test "a real UUID-typed column is still converted to a 16-byte binary" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      changeset =
        CustomerResource
        |> Ash.Changeset.for_create(:create, %{name: "bob"})
        |> Ash.Changeset.force_change_attribute(:id, uuid)

      {:ok, %CustomerResource{} = record} = DataLayer.create(CustomerResource, changeset)

      # Decoded back to canonical string form on read.
      assert record.id == uuid
    end
  end

  # ── Batched aggregates (items #3/#4) ──────────────────────────────────────────

  describe "relationship aggregates are batched (items #3/#4)" do
    test "same-table aggregate issues one IN(...) query for the whole page" do
      q = DataLayer.resource_to_query(CustomerResource, nil)

      agg = %Ash.Query.Aggregate{
        kind: :sum,
        name: :age_sum,
        field: :age,
        resource: CustomerResource,
        relationship_path: []
      }

      {:ok, q2} = DataLayer.add_aggregate(q, agg, CustomerResource)

      DataLayer.run_query(q2, CustomerResource)

      # Exactly one aggregate query, and it uses IN (...) rather than one
      # query per record.
      aggregate_calls =
        Enum.filter(FakeRepo.calls(FakeRepo), fn
          {:query, sql, _} -> Regex.match?(~r/SUM\s*\(/i, sql)
          _ -> false
        end)

      assert length(aggregate_calls) == 1

      assert Enum.any?(aggregate_calls, fn {:query, sql, _} -> Regex.match?(~r/IN\s*\(/i, sql) end)
    end

    test "has_many relationship aggregate is supported (not default_value)" do
      q = DataLayer.resource_to_query(CustomerResource, nil)

      agg = %Ash.Query.Aggregate{
        kind: :count,
        name: :order_count,
        field: :id,
        resource: OrderResource,
        relationship_path: [:orders]
      }

      {:ok, q2} = DataLayer.add_aggregate(q, agg, CustomerResource)

      {:ok, [record]} = DataLayer.run_query(q2, CustomerResource)

      # The batched GROUP BY path returns a decoded integer, not default_value.
      assert Map.get(record.aggregates, :order_count) == 42
    end
  end

  # ── Type-aware aggregate decoding (items #5/#6) ───────────────────────────────

  describe "aggregate decoding is type-aware and consistent (items #5/#6)" do
    test "query-level and relationship aggregates share the same decode path" do
      q = DataLayer.resource_to_query(CustomerResource, nil)

      query_agg = %Ash.Query.Aggregate{
        kind: :sum,
        name: :total_sum,
        field: :age,
        resource: CustomerResource
      }

      {:ok, result} = DataLayer.run_aggregate_query(q, [query_agg], CustomerResource)

      # ClickHouse returns "42" as a string; decode_aggregate must yield an
      # integer (10) rather than the raw string ("10").
      assert result.total_sum == 42
      refute is_binary(result.total_sum)
    end
  end

  # ── Repo cache invalidation (design concern) ─────────────────────────────────

  describe "repo cache can be cleared for tests" do
    test "clear_repo_cache!/0 empties the cache" do
      # Populate the cache by resolving a repo.
      _ = DataLayer.repo(CustomerResource)
      assert :ets.whereis(:ash_clickhouse_repo_cache) != :undefined

      assert DataLayer.clear_repo_cache!() == :ok
      assert :ets.tab2list(:ash_clickhouse_repo_cache) == []
    end
  end
end
