defmodule AshClickhouse.QueryBuilderTest do
  @moduledoc "Unit tests for AshClickhouse.DataLayer.QueryBuilder."
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.Query

  defp query(overrides) do
    struct!(Query, Map.merge(%{table: "users", database: nil, filters: [], sorts: [], limit: nil, offset: nil, select: nil, distinct: nil, group_by: nil}, overrides))
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
          query(%{database: "app", filters: [filter], sorts: [{:name, :asc}], limit: 10, offset: 5, select: [:id, :name]})
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
      assert params == [2, 1]
    end

    test "is_nil" do
      filter = %{operator: :is_nil, left: %{name: :deleted_at}, right: %{value: true}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `deleted_at` IS NULL"
      assert params == []
    end
  end

  describe "qualified_table/2" do
    test "with and without database" do
      assert QueryBuilder.qualified_table("users", nil) == "`users`"
      assert QueryBuilder.qualified_table("users", "app") == "`app`.`users`"
    end
  end
end
