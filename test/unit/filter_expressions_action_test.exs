defmodule AshClickhouse.FilterExpressionsActionTest do
  @moduledoc """
  Action-level coverage for the filter expression translation.

  These tests exercise the *Ash* path — building and running a query — rather
  than the query builder in isolation, so a filter that the layer cannot
  express is caught at query-build time instead of failing part-way through
  execution.
  """
  use ExUnit.Case, async: false

  import Ash.Expr
  import Ash.Query

  alias AshClickhouse.CompatCustomer
  alias AshClickhouse.DataLayer
  alias AshClickhouse.FakeRepo

  setup do
    {:ok, _pid} = FakeRepo.start()
    FakeRepo.reset()
    on_exit(&FakeRepo.reset/0)

    :ok
  end

  describe "an unsupported filter is refused when the query is built" do
    test "the query is invalid and carries an error naming the expression" do
      query = filter(Ash.Query.new(CompatCustomer), expr(is_distinct_from(name, "x")))

      refute query.valid?
      assert [error] = query.errors
      assert Exception.message(error) =~ "is_distinct_from"
    end

    test "no query reaches the database" do
      query = filter(Ash.Query.new(CompatCustomer), expr(is_distinct_from(name, "x")))

      assert {:error, error} = Ash.read(query)

      assert Exception.message(error) =~ "is_distinct_from"
      assert FakeRepo.query_count() == 0
    end
  end

  describe "a supported filter is accepted when the query is built" do
    test "the query is valid" do
      query = filter(Ash.Query.new(CompatCustomer), name != "bob")

      assert query.valid?
      assert query.errors == []
    end

    test "the read completes and returns the rows" do
      FakeRepo.default_response([["id-1", "alice", "alice@example.com", 30, "gold"]])

      query = filter(Ash.Query.new(CompatCustomer), name != "bob")

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"
    end
  end

  describe "the layer publishes the ClickHouse functions available in filters" do
    test "the published functions are exposed" do
      assert AshClickhouse.Functions.Match in DataLayer.functions(CompatCustomer)
    end

    test "a published function is usable in a filter" do
      FakeRepo.default_response([["id-1", "alice", "alice@example.com", 30, "gold"]])

      query = filter(Ash.Query.new(CompatCustomer), match(name, "^ali"))

      assert query.valid?

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"

      assert [sql] = FakeRepo.queries()
      assert sql =~ "match(`name`, ?)"
    end

    test "an unpublished function is refused" do
      query = filter(Ash.Query.new(CompatCustomer), unknown_function(name, "x"))

      refute query.valid?
      assert [error] = query.errors
      assert Exception.message(error) =~ "unknown_function"
    end
  end

  describe "reading with the translated filters" do
    test "an inequality filter completes and returns the expected rows" do
      FakeRepo.default_response([["id-1", "alice", "alice@example.com", 30, "gold"]])

      query = filter(Ash.Query.new(CompatCustomer), name != "bob")

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"

      assert [sql] = FakeRepo.queries()
      assert sql =~ "`name` != ?"
    end

    test "a containment filter completes and returns the expected rows" do
      FakeRepo.default_response([["id-1", "alice", "alice@example.com", 30, "gold"]])

      query = filter(Ash.Query.new(CompatCustomer), contains(name, "li"))

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"

      assert [sql] = FakeRepo.queries()
      assert sql =~ "positionCaseInsensitive(`name`, ?)"
    end

    test "the literal is bound as a parameter rather than interpolated" do
      FakeRepo.default_response([["id-1", "alice", "alice@example.com", 30, "gold"]])

      query = filter(Ash.Query.new(CompatCustomer), name != "bob")

      assert {:ok, [_record]} = Ash.read(query)

      assert [{:query, sql, params}] = FakeRepo.calls()
      refute sql =~ "bob"
      assert "bob" in params
    end
  end
end
