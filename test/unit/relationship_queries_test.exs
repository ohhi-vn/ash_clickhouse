defmodule AshClickhouse.RelationshipQueriesTest do
  @moduledoc """
  Coverage for the queries that reach across a relationship.

  A relationship filter is answered with a semi-join — the queried resource's
  key is tested against a subquery over the related table — so the number of
  returned rows does not depend on how many related rows match.
  """
  use ExUnit.Case, async: false

  import Ash.Query

  alias AshClickhouse.CompatCustomer
  alias AshClickhouse.CompatOrder
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

  describe "the layer reports the relationship capabilities it has" do
    test "filtering across a relationship is supported" do
      assert DataLayer.can?(CompatCustomer, {:filter_relationship, :orders})
    end

    test "a relationship path of more than one hop is not supported" do
      assert DataLayer.can?(CompatCustomer, {:filter_relationship, [:orders]})
      refute DataLayer.can?(CompatCustomer, {:filter_relationship, [:orders, :lines]})
    end

    test "aggregating over a relationship is supported" do
      assert DataLayer.can?(CompatCustomer, {:aggregate_relationship, :orders})
    end

    test "an unrelated existence check is supported" do
      assert DataLayer.can?(CompatCustomer, {:exists, :unrelated})
    end
  end

  describe "a filter across a relationship is translated to a semi-join" do
    test "the predicate tests the queried resource's key against a subquery" do
      filter = %Ash.Query.Operator.Eq{
        left: %Ash.Query.Ref{
          attribute: :status,
          relationship_path: [:orders],
          resource: CompatOrder
        },
        right: "paid"
      }

      {sql, params} = QueryBuilder.build_where_clause([filter], CompatCustomer)

      assert sql ==
               " WHERE `id` IN (SELECT `customer_id` FROM `compat_orders` WHERE `status` = ?)"

      assert params == ["paid"]
    end

    test "the subquery selects the related resource's join key" do
      filter = %Ash.Query.Operator.Eq{
        left: %Ash.Query.Ref{
          attribute: :status,
          relationship_path: [:orders],
          resource: CompatOrder
        },
        right: "paid"
      }

      {sql, _params} = QueryBuilder.build_where_clause([filter], CompatCustomer)

      assert sql =~ "SELECT `customer_id` FROM `compat_orders`"
    end

    test "the inner predicate's parameters are bound" do
      filter = %Ash.Query.Operator.GreaterThan{
        left: %Ash.Query.Ref{
          attribute: :total,
          relationship_path: [:orders],
          resource: CompatOrder
        },
        right: 100
      }

      {sql, params} = QueryBuilder.build_where_clause([filter], CompatCustomer)

      assert sql =~ "`total` > ?"
      assert params == [100]
    end
  end

  describe "an existence check over an unrelated resource is translated" do
    test "the predicate tests for the existence of a matching row" do
      exists = %Ash.Query.Exists{
        related?: false,
        resource: CompatOrder,
        expr: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :status, relationship_path: [], resource: CompatOrder},
          right: "paid"
        }
      }

      {sql, params} = QueryBuilder.build_where_clause([exists], CompatCustomer)

      assert sql == " WHERE EXISTS (SELECT 1 FROM `compat_orders` WHERE `status` = ?)"
      assert params == ["paid"]
    end
  end

  describe "a filter across a relationship that cannot be expressed is refused" do
    test "a two-hop relationship filter is refused when the data layer query is built" do
      query = filter(Ash.Query.new(CompatCustomer), orders.lines.sku == "abc")

      assert {:error, error} = Ash.Query.data_layer_query(query, [])
      assert error_message(error) =~ "relationship path"
    end

    test "the read fails and no query reaches the database" do
      query = filter(Ash.Query.new(CompatCustomer), orders.lines.sku == "abc")

      assert {:error, error} = Ash.read(query)
      assert error_message(error) =~ "relationship path"
      assert FakeRepo.query_count() == 0
    end
  end

  describe "reading with a filter across a relationship" do
    test "the query is valid and the semi-join is issued" do
      FakeRepo.default_response([@customer_row])

      query = filter(Ash.Query.new(CompatCustomer), orders.status == "paid")

      assert query.valid?

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"

      assert [sql] = FakeRepo.queries()
      assert sql =~ "`id` IN (SELECT `customer_id` FROM `compat_orders`"
    end

    test "a row with a matching related row is returned" do
      FakeRepo.default_response([@customer_row])

      query = filter(Ash.Query.new(CompatCustomer), orders.status == "paid")

      assert {:ok, [record]} = Ash.read(query)
      assert record.id == "id-1"
    end

    test "the query combines with the query's own filter" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> filter(name == "alice")
        |> filter(orders.status == "paid")

      assert {:ok, [_record]} = Ash.read(query)

      assert [sql] = FakeRepo.queries()
      assert sql =~ "`name` = ?"
      assert sql =~ "`id` IN (SELECT `customer_id` FROM `compat_orders`"
    end

    test "the number of returned rows does not depend on the number of matches" do
      # The semi-join returns one row per matching customer, however many
      # orders matched.
      FakeRepo.default_response([@customer_row, @customer_row])

      query = filter(Ash.Query.new(CompatCustomer), orders.status == "paid")

      assert {:ok, records} = Ash.read(query)
      assert length(records) == 2
    end
  end

  describe "reading with an unrelated existence check" do
    test "the query is valid and the existence subquery is issued" do
      FakeRepo.default_response([@customer_row])

      query = filter(Ash.Query.new(CompatCustomer), exists(CompatOrder, status == "paid"))

      assert query.valid?

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"

      assert [sql] = FakeRepo.queries()
      assert sql =~ "EXISTS (SELECT 1 FROM `compat_orders`"
    end
  end

  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: Exception.message(error)
end
