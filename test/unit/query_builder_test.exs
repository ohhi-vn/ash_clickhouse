defmodule AshClickhouse.QueryBuilderTest do
  @moduledoc "Unit tests for AshClickhouse.DataLayer.QueryBuilder."
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.Query

  defp query(overrides) do
    struct!(
      Query,
      Map.merge(
        %{
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

  describe "build_optimized_query/1" do
    test "basic SELECT *" do
      {sql, params} = QueryBuilder.build_optimized_query(query(%{}))
      assert sql == "SELECT * FROM `users`"
      assert params == []
    end

    test "qualified table with database" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{database: "app"}))
      assert sql == "SELECT * FROM `app`.`users`"
    end

    test "select projection" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{select: [:id, :name]}))
      assert sql == "SELECT `id`, `name` FROM `users`"
    end

    test "distinct projection" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{distinct: [:name]}))
      assert sql == "SELECT DISTINCT `name` FROM `users`"
    end

    test "where, order, limit, offset" do
      filter = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}

      {sql, params} =
        QueryBuilder.build_optimized_query(
          query(%{
            database: "app",
            filters: [filter],
            sorts: [{:name, :asc}],
            limit: 10,
            offset: 5,
            select: [:id, :name]
          })
        )

      assert sql ==
               "SELECT `id`, `name` FROM `app`.`users` WHERE `status` = ? ORDER BY `name` ASC LIMIT 10 OFFSET 5"

      assert params == ["active"]
    end

    test "group by" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{group_by: [:status]}))
      assert sql == "SELECT * FROM `users` GROUP BY `status`"
    end
  end

  describe "build_predicate/1" do
    test "comparison operators" do
      filter = %{operator: :>, left: %{name: :age}, right: %{value: 18}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `age` > ?"
      assert params == [18]
    end

    test "logical operators" do
      left = %{operator: :eq, left: %{name: :a}, right: %{value: 1}}
      right = %{operator: :eq, left: %{name: :b}, right: %{value: 2}}

      {sql, params} =
        QueryBuilder.build_where_clause([%{op: :and, left: left, right: right}])

      assert sql == " WHERE (`a` = ? AND `b` = ?)"
      assert params == [1, 2]
    end

    test "is_nil" do
      filter = %{operator: :is_nil, left: %{name: :deleted_at}, right: %{value: true}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `deleted_at` IS NULL"
      assert params == []
    end
  end

  describe "build_where_clause/1" do
    test "an empty filter list yields no clause" do
      assert QueryBuilder.build_where_clause([]) == {"", []}
    end

    test "drops untranslatable filters when raise_on_untranslatable is disabled" do
      Application.put_env(:ash_clickhouse, :raise_on_untranslatable_filter, false)
      on_exit(fn -> Application.delete_env(:ash_clickhouse, :raise_on_untranslatable_filter) end)

      assert QueryBuilder.build_where_clause([:garbage]) == {"", []}
      assert QueryBuilder.build_where_clause([nil]) == {"", []}
    end

    test "a conjunction/or with an untranslatable child is dropped" do
      Application.put_env(:ash_clickhouse, :raise_on_untranslatable_filter, false)
      on_exit(fn -> Application.delete_env(:ash_clickhouse, :raise_on_untranslatable_filter) end)

      ok = %{operator: :eq, left: %{name: :name}, right: %{value: "x"}}

      assert QueryBuilder.build_where_clause([%{op: :and, left: ok, right: :garbage}]) ==
               {"", []}

      assert QueryBuilder.build_where_clause([%{op: :or, left: ok, right: :garbage}]) ==
               {"", []}

      assert QueryBuilder.build_where_clause([
               %Ash.Query.BooleanExpression{op: :not, left: :garbage}
             ]) == {"", []}

      assert QueryBuilder.build_where_clause([%Ash.Query.Not{expression: :garbage}]) ==
               {"", []}
    end

    test "raises QueryError for untranslatable filters by default" do
      assert_raise AshClickhouse.Error.QueryError, fn ->
        QueryBuilder.build_where_clause([:garbage])
      end
    end
  end

  describe "operator struct predicates" do
    test "Ash.Query.Operator structs with a Ref left-hand side" do
      filter = %Ash.Query.Operator.Eq{
        left: %Ash.Query.Ref{attribute: %{name: :name}, relationship_path: []},
        right: "x"
      }

      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `name` = ?"
      assert params == ["x"]
    end

    test "operator structs with an atom left-hand side" do
      filter = %{operator: :eq, left: :name, right: "x"}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `name` = ?"
      assert params == ["x"]
    end

    test "operator structs with a plain map left and raw right" do
      filter = %{operator: :eq, left: %{name: :name}, right: "x"}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `name` = ?"
      assert params == ["x"]
    end

    test "legacy op/name/right predicate shape" do
      filter = %{op: :eq, name: :name, right: "x"}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `name` = ?"
      assert params == ["x"]
    end

    test "not_in with a non-list value emits a single placeholder" do
      filter = %{op: :not_in, name: :id, right: "x"}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `id` NOT IN (?)"
      assert params == ["x"]
    end
  end

  describe "get_filter_columns/1" do
    test "collects columns from operator structs, maps, and skips unknown terms" do
      ref = %Ash.Query.Ref{attribute: :name, relationship_path: []}

      assert QueryBuilder.get_filter_columns([
               %{operator: :eq, left: ref, right: "x"},
               %{name: :status},
               :garbage
             ]) == [:status, :name]
    end
  end

  describe "qualified_table/2" do
    test "with and without database" do
      assert QueryBuilder.qualified_table("users", nil) == "`users`"
      assert QueryBuilder.qualified_table("users", "app") == "`app`.`users`"
    end

    test "ignores a non-binary database" do
      assert QueryBuilder.qualified_table("users", 42) == "`users`"
    end
  end

  describe "invalid limit/offset" do
    test "raises for a non-integer non-binary limit" do
      assert_raise ArgumentError, fn ->
        QueryBuilder.build_optimized_query(query(%{limit: :many}))
      end
    end
  end
end
