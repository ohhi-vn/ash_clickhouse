defmodule AshClickhouse.QueryBuilderExtraTest do
  @moduledoc "Additional unit tests for AshClickhouse.DataLayer.QueryBuilder."
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

  describe "build_predicate/1 operators" do
    test "not_eq" do
      filter = %{operator: :not_eq, left: %{name: :status}, right: %{value: "inactive"}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `status` != ?"
      assert params == ["inactive"]
    end

    test "equality with :== " do
      filter = %{operator: :==, left: %{name: :status}, right: %{value: "active"}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `status` = ?"
      assert params == ["active"]
    end

    test "greater/less or equal" do
      gte = %{operator: :>=, left: %{name: :age}, right: %{value: 18}}
      lte = %{operator: :<=, left: %{name: :age}, right: %{value: 65}}
      {sql, params} = QueryBuilder.build_where_clause([gte, lte])
      assert String.contains?(sql, "`age` >= ?")
      assert String.contains?(sql, "`age` <= ?")
      assert params == [18, 65]
    end

    test "in with a list expands to placeholders" do
      filter = %{operator: :in, left: %{name: :status}, right: %{value: ["a", "b", "c"]}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `status` IN (?, ?, ?)"
      assert params == ["a", "b", "c"]
    end

    test "in with a single value" do
      filter = %{operator: :in, left: %{name: :status}, right: %{value: "a"}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `status` IN (?)"
      assert params == ["a"]
    end

    test "not_in" do
      filter = %{operator: :not_in, left: %{name: :status}, right: %{value: ["a", "b"]}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `status` NOT IN (?, ?)"
      assert params == ["a", "b"]
    end

    test "contains maps to positionCaseInsensitive" do
      filter = %{operator: :contains, left: %{name: :name}, right: %{value: "oh"}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE positionCaseInsensitive(`name`, ?) > 0"
      assert params == ["oh"]
    end

    test "starts_with and ends_with use LIKE" do
      sw = %{operator: :starts_with, left: %{name: :name}, right: %{value: "a"}}
      ew = %{operator: :ends_with, left: %{name: :name}, right: %{value: "z"}}
      {sql, params} = QueryBuilder.build_where_clause([sw, ew])
      assert String.contains?(sql, "`name` LIKE ?")
      assert params == ["a%", "%z"]
    end

    test "or combines predicates" do
      left = %{operator: :eq, left: %{name: :a}, right: %{value: 1}}
      right = %{operator: :eq, left: %{name: :b}, right: %{value: 2}}
      {sql, params} = QueryBuilder.build_where_clause([%{op: :or, left: left, right: right}])
      assert sql == " WHERE (`a` = ? OR `b` = ?)"
      assert params == [1, 2]
    end

    test "not negates a predicate" do
      child = %{operator: :eq, left: %{name: :a}, right: %{value: 1}}
      {sql, params} = QueryBuilder.build_where_clause([%Ash.Query.Not{expression: child}])
      assert sql == " WHERE (NOT `a` = ?)"
      assert params == [1]
    end

    test "is_nil false renders IS NOT NULL" do
      filter = %{operator: :is_nil, left: %{name: :deleted_at}, right: %{value: false}}
      {sql, params} = QueryBuilder.build_where_clause([filter])
      assert sql == " WHERE `deleted_at` IS NOT NULL"
      assert params == []
    end
  end

  describe "build_optimized_query/1" do
    test "distinct plus select" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{distinct: [:name], select: [:name]}))
      assert sql == "SELECT DISTINCT `name` FROM `users`"
    end

    test "group by with aggregate select" do
      {sql, _} =
        QueryBuilder.build_optimized_query(query(%{group_by: [:status], select: [:status]}))

      assert sql == "SELECT `status` FROM `users` GROUP BY `status`"
    end

    test "empty filters produce no WHERE clause" do
      {sql, params} = QueryBuilder.build_optimized_query(query(%{}))
      refute String.contains?(sql, "WHERE")
      assert params == []
    end
  end

  describe "get_filter_columns/1" do
    test "collects columns from and/or trees" do
      left = %{operator: :eq, left: %{name: :a}, right: %{value: 1}}
      right = %{operator: :eq, left: %{name: :b}, right: %{value: 2}}
      combined = %{op: :and, left: left, right: right}

      assert QueryBuilder.get_filter_columns([combined]) == [:a, :b]
    end

    test "returns empty list for no filters" do
      assert QueryBuilder.get_filter_columns([]) == []
    end
  end

  describe "cql_identifier/1" do
    test "quotes identifiers" do
      assert QueryBuilder.cql_identifier(:users) == "`users`"
      assert QueryBuilder.cql_identifier("my`table") == "`my``table`"
    end
  end

  describe "qualified_table/2 with non-binary table" do
    test "stringifies atoms" do
      assert QueryBuilder.qualified_table(:users, nil) == "`users`"
      assert QueryBuilder.qualified_table(:users, "app") == "`app`.`users`"
    end
  end
end
