defmodule AshClickhouse.CombinationQueriesTest do
  @moduledoc """
  Coverage for the combination queries — a query that unions several others.

  A combination query is run as a *single* statement against the database: the
  parts' statements are combined with ClickHouse's `UNION` operators.
  """
  use ExUnit.Case, async: false

  import Ash.Expr
  import Ash.Query

  alias Ash.Query.Combination
  alias AshClickhouse.CompatCustomer
  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.FakeRepo

  @customer_row ["id-1", "alice", "alice@example.com", 30, "gold"]

  setup do
    {:ok, _pid} = FakeRepo.start()
    FakeRepo.reset()
    on_exit(&FakeRepo.reset/0)

    :ok
  end

  describe "the layer reports the combination kinds it supports" do
    test "combining queries is supported" do
      assert DataLayer.can?(CompatCustomer, :combine)
    end

    test "the union kinds are supported" do
      assert DataLayer.can?(CompatCustomer, {:combine, :base})
      assert DataLayer.can?(CompatCustomer, {:combine, :union})
      assert DataLayer.can?(CompatCustomer, {:combine, :union_all})
    end

    test "an unsupported combination kind is refused" do
      refute DataLayer.can?(CompatCustomer, {:combine, :except})
      refute DataLayer.can?(CompatCustomer, {:combine, :intersect})
    end
  end

  describe "combination_of/3" do
    test "the combined statement combines the parts with the expected set operator" do
      base = DataLayer.resource_to_query(CompatCustomer, nil)
      second = DataLayer.resource_to_query(CompatCustomer, nil)

      {:ok, combined} =
        DataLayer.combination_of([{:base, base}, {:union_all, second}], CompatCustomer, nil)

      {sql, _params} = QueryBuilder.build_optimized_query(combined)

      assert sql =~ "UNION ALL"
      assert String.split(sql, "UNION ALL") |> length() == 2
    end

    test "a deduplicating union uses UNION DISTINCT" do
      base = DataLayer.resource_to_query(CompatCustomer, nil)
      second = DataLayer.resource_to_query(CompatCustomer, nil)

      {:ok, combined} =
        DataLayer.combination_of([{:base, base}, {:union, second}], CompatCustomer, nil)

      {sql, _params} = QueryBuilder.build_optimized_query(combined)

      assert sql =~ "UNION DISTINCT"
    end
  end

  describe "combination_acc/1" do
    test "the accumulator returns the parts in the order Ash supplied them" do
      first = DataLayer.resource_to_query(CompatCustomer, nil)
      second = DataLayer.resource_to_query(CompatCustomer, nil)

      first_acc = DataLayer.combination_acc(first)
      assert [{first_sql, first_params}] = first_acc
      assert first_sql =~ "FROM `compat_customers`"
      assert first_params == []

      {:ok, second} = DataLayer.set_context(CompatCustomer, second, %{})

      second = %{second | combination: first_acc}

      second_acc = DataLayer.combination_acc(second)
      assert length(second_acc) == 2

      assert [{^first_sql, ^first_params}, {second_sql, _second_params}] = second_acc
      assert second_sql =~ "FROM `compat_customers`"
    end
  end

  describe "reading a union query" do
    test "the read completes and returns the combined results" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.combination_of([
          Combination.base(filter: expr(name == "alice")),
          Combination.union_all(filter: expr(name == "bob"))
        ])

      assert query.valid?

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"
    end

    test "one statement is issued to the database for the combined read" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.combination_of([
          Combination.base(filter: expr(name == "alice")),
          Combination.union_all(filter: expr(name == "bob"))
        ])

      assert {:ok, [_record]} = Ash.read(query)
      assert FakeRepo.query_count() == 1
    end

    test "each part keeps its own filter" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.combination_of([
          Combination.base(filter: expr(name == "alice")),
          Combination.union_all(filter: expr(name == "bob"))
        ])

      assert {:ok, [_record]} = Ash.read(query)

      assert [sql] = FakeRepo.queries()
      assert sql =~ "`name` = ?"
      assert sql =~ "UNION ALL"

      assert [{:query, _statement, params}] = FakeRepo.calls()
      assert "alice" in params
      assert "bob" in params
    end

    test "each part keeps its own limit and sort" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.combination_of([
          Combination.base(
            filter: expr(name == "alice"),
            limit: 1,
            sort: [name: :asc]
          ),
          Combination.union_all(filter: expr(name == "bob"), limit: 2)
        ])

      assert {:ok, [_record]} = Ash.read(query)

      assert [sql] = FakeRepo.queries()
      assert sql =~ "LIMIT 1"
      assert sql =~ "LIMIT 2"
      assert sql =~ "ORDER BY `name` ASC"
    end

    test "the parts appear in the order Ash supplied them" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.combination_of([
          Combination.base(filter: expr(name == "alice")),
          Combination.union_all(filter: expr(name == "bob"))
        ])

      assert {:ok, [_record]} = Ash.read(query)

      assert [{:query, _statement, params}] = FakeRepo.calls()
      assert params == ["alice", "bob"]
    end

    test "a concatenating union keeps duplicate rows" do
      FakeRepo.default_response([@customer_row, @customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.combination_of([
          Combination.base(filter: expr(name == "alice")),
          Combination.union_all(filter: expr(name == "alice"))
        ])

      assert {:ok, records} = Ash.read(query)
      assert length(records) == 2

      assert [sql] = FakeRepo.queries()
      assert sql =~ "UNION ALL"
      refute sql =~ "UNION DISTINCT"
    end

    test "a deduplicating union removes duplicate rows" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.combination_of([
          Combination.base(filter: expr(name == "alice")),
          Combination.union(filter: expr(name == "alice"))
        ])

      assert {:ok, records} = Ash.read(query)
      assert length(records) == 1

      assert [sql] = FakeRepo.queries()
      assert sql =~ "UNION DISTINCT"
    end
  end
end
