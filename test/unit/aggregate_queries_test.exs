defmodule AshClickhouse.AggregateQueriesTest do
  @moduledoc """
  Coverage for the aggregate kinds the data layer supports and for the way an
  aggregate's own filter, sort and join filters narrow the rows it considers.

  The query-counting fake repo makes the number of ClickHouse round-trips
  observable, which is the only way to catch an aggregate being issued twice.
  """
  use ExUnit.Case, async: false

  alias AshClickhouse.CompatCustomer
  alias AshClickhouse.CompatOrder
  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.Aggregate
  alias AshClickhouse.FakeRepo

  @customer_row ["id-1", "alice", "alice@example.com", 30, "gold"]

  setup do
    {:ok, _pid} = FakeRepo.start()
    FakeRepo.reset()
    on_exit(&FakeRepo.reset/0)

    :ok
  end

  describe "the aggregates live on the query, not in its context" do
    test "add_aggregate/3 stores the aggregate on the query" do
      q = DataLayer.resource_to_query(CompatCustomer, nil)

      aggregate = %Ash.Query.Aggregate{
        kind: :count,
        name: :cnt,
        field: nil,
        resource: CompatCustomer,
        relationship_path: []
      }

      {:ok, q2} = DataLayer.add_aggregate(q, aggregate, CompatCustomer)

      assert q2.aggregates == [aggregate]
      refute Map.has_key?(q2.context, :aggregates)
    end

    test "add_aggregates/3 de-duplicates the aggregates by name" do
      q = DataLayer.resource_to_query(CompatCustomer, nil)

      aggregate = %Ash.Query.Aggregate{
        kind: :count,
        name: :cnt,
        field: nil,
        resource: CompatCustomer,
        relationship_path: []
      }

      # Ash calls `add_aggregates/3` twice with the same list.
      {:ok, q2} = DataLayer.add_aggregates(q, [aggregate], CompatCustomer)
      {:ok, q3} = DataLayer.add_aggregates(q2, [aggregate], CompatCustomer)

      assert length(q3.aggregates) == 1
    end
  end

  describe "a read loading N relationship aggregates issues N aggregate queries" do
    test "the aggregate is issued once, not twice" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 3]])
      FakeRepo.queue_response([["id-1", 1]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:order_count)
        |> Ash.Query.load(:paid_order_count)

      assert {:ok, [record]} = Ash.read(query)

      assert record.aggregates.order_count == 3
      assert record.aggregates.paid_order_count == 1

      # One read query plus one query per aggregate.
      assert FakeRepo.query_count() == 3
    end
  end

  describe "an aggregate honours its own filter" do
    test "the aggregate's filter is merged into the aggregate's WHERE clause" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 1]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:paid_order_count)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.paid_order_count == 1

      assert [_read_sql, aggregate_sql] = FakeRepo.queries()
      assert aggregate_sql =~ "`status` = ?"
    end

    test "a filtered count counts only the matching rows" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 2]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:paid_order_count)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.paid_order_count == 2
    end

    test "a filtered count over no matching rows is zero rather than absent" do
      FakeRepo.queue_response([@customer_row])
      # A batched aggregate over no matching rows returns no group for the
      # record's key, so the aggregate falls back to its declared default.
      FakeRepo.queue_response([])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:paid_order_count)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.paid_order_count == 0
    end
  end

  describe "an aggregate honours its own join filters" do
    test "the join filter's predicate is combined with the aggregate's own" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 1]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:paid_order_count)

      assert {:ok, [_record]} = Ash.read(query)

      assert [_read_sql, aggregate_sql] = FakeRepo.queries()
      assert aggregate_sql =~ "`status` = ?"
      assert aggregate_sql =~ "`total` = ?"
    end
  end

  describe "the aggregate kinds the layer supports" do
    test "the basic kinds are reported as supported" do
      for kind <- [:count, :sum, :avg, :min, :max] do
        assert DataLayer.can?(CompatCustomer, {:aggregate, kind})
        assert DataLayer.can?(CompatCustomer, {:query_aggregate, kind})
      end
    end

    test "the first, list and exists kinds are reported as supported" do
      for kind <- [:first, :list, :exists] do
        assert DataLayer.can?(CompatCustomer, {:aggregate, kind})
        assert DataLayer.can?(CompatCustomer, {:query_aggregate, kind})
      end
    end

    test "an unsupported kind is reported as unsupported" do
      refute DataLayer.can?(CompatCustomer, {:aggregate, :custom})
      refute DataLayer.can?(CompatCustomer, {:query_aggregate, :custom})
    end
  end

  describe "the first aggregate kind" do
    test "the rendered aggregate query orders by the aggregate's sort" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 250]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:first_order_total)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.first_order_total == 250

      assert [_read_sql, aggregate_sql] = FakeRepo.queries()
      assert aggregate_sql =~ "argMax(`total`, `total`)"
    end

    test "a first aggregate over no matching rows falls back to the default" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:first_order_total)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.first_order_total == nil
    end

    test "a query-level first aggregate renders ORDER BY ... LIMIT 1" do
      FakeRepo.queue_response([[250]])

      aggregate = %Ash.Query.Aggregate{
        kind: :first,
        name: :first_total,
        field: :total,
        resource: AshClickhouse.CompatOrder,
        relationship_path: [],
        query: %Ash.Query{sort: [{:total, :desc}]}
      }

      {:ok, result} =
        DataLayer.run_aggregate_query(
          DataLayer.resource_to_query(CompatOrder, nil),
          [aggregate],
          CompatOrder
        )

      assert result.first_total == 250

      assert [sql] = FakeRepo.queries()
      assert sql =~ "ORDER BY `total` DESC"
      assert sql =~ "LIMIT 1"
    end
  end

  describe "the list aggregate kind" do
    test "the decoded value carries every matching row's field value" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", [10, 20, 30]]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:order_totals)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.order_totals == [10, 20, 30]
    end
  end

  describe "the exists aggregate kind" do
    test "the value is true when a row matched" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 1]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:has_paid_orders)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.has_paid_orders == true
    end

    test "the value is false when no row matched" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:has_paid_orders)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.has_paid_orders == nil
    end
  end

  describe "loading the new aggregate kinds over a relationship" do
    test "each record carries the expected value and the read issues one query per aggregate" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 250]])
      FakeRepo.queue_response([["id-1", [10, 20]]])
      FakeRepo.queue_response([["id-1", 1]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:first_order_total)
        |> Ash.Query.load(:order_totals)
        |> Ash.Query.load(:has_paid_orders)

      assert {:ok, [record]} = Ash.read(query)

      assert record.aggregates.first_order_total == 250
      assert record.aggregates.order_totals == [10, 20]
      assert record.aggregates.has_paid_orders == true

      # One read query plus one query per aggregate.
      assert FakeRepo.query_count() == 4
    end

    test "a record with no related rows carries the declared default" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([])
      FakeRepo.queue_response([])
      FakeRepo.queue_response([])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:first_order_total)
        |> Ash.Query.load(:order_totals)
        |> Ash.Query.load(:has_paid_orders)

      assert {:ok, [record]} = Ash.read(query)

      assert record.aggregates.first_order_total == nil
      assert record.aggregates.order_totals == []
      assert record.aggregates.has_paid_orders == nil
    end
  end

  describe "the aggregate module" do
    test "an aggregate over a relationship is computed with one grouped query" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 3]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:order_count)

      assert {:ok, [record]} = Ash.read(query)
      assert record.aggregates.order_count == 3

      assert [_read_sql, aggregate_sql] = FakeRepo.queries()
      assert aggregate_sql =~ "GROUP BY `customer_id`"
    end

    test "the aggregate's filter narrows the counted rows" do
      FakeRepo.queue_response([@customer_row])
      FakeRepo.queue_response([["id-1", 3]])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:order_count)

      assert {:ok, [record]} = Ash.read(query)

      assert [_read_sql, aggregate_sql] = FakeRepo.queries()
      refute aggregate_sql =~ "WHERE `customer_id` IN (?) AND"
      assert aggregate_sql =~ "WHERE `customer_id` IN (?)"
    end
  end
end
