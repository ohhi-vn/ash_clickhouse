defmodule AshClickhouse.QueryBuilderComplexTest do
  @moduledoc """
  Complex / combinatorial unit tests for `AshClickhouse.DataLayer.QueryBuilder`.

  Focuses on deeply nested boolean trees, mixed operators, multiple filters in a
  single query, and the full SELECT-clause assembly so regressions in SQL
  generation are caught early.
  """
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

  defp ref(name), do: %{name: name}

  defp where(filters), do: QueryBuilder.build_where_clause(filters)

  describe "deeply nested boolean trees" do
    test "three-level AND/OR nesting with NOT" do
      a = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      b = %{operator: :eq, left: ref(:b), right: %{value: 2}}
      c = %{operator: :>, left: ref(:c), right: %{value: 3}}
      d = %{operator: :<, left: ref(:d), right: %{value: 4}}

      # (a AND (b OR (NOT c))) OR d
      inner = %{op: :or, left: b, right: %Ash.Query.Not{expression: c}}
      left = %{op: :and, left: a, right: inner}
      tree = %{op: :or, left: left, right: d}

      {sql, params} = where([tree])

      assert sql ==
               " WHERE ((`a` = ? AND (`b` = ? OR (NOT `c` > ?))) OR `d` < ?)"

      assert params == [1, 2, 3, 4]
    end

    test "NOT of a BooleanExpression (legacy shape)" do
      child = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      tree = %Ash.Query.BooleanExpression{op: :not, left: child, right: nil}
      {sql, params} = where([tree])
      assert sql == " WHERE (NOT `a` = ?)"
      assert params == [1]
    end

    test "nested AND inside OR inside AND" do
      a = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      b = %{operator: :eq, left: ref(:b), right: %{value: 2}}
      c = %{operator: :eq, left: ref(:c), right: %{value: 3}}

      inner = %{op: :and, left: b, right: c}
      tree = %{op: :or, left: a, right: inner}

      {sql, params} = where([%{op: :and, left: a, right: tree}])
      assert sql == " WHERE (`a` = ? AND (`a` = ? OR (`b` = ? AND `c` = ?)))"
      assert params == [1, 1, 2, 3]
    end
  end

  describe "multiple filters in a single query" do
    test "filters are AND-combined in declaration order" do
      f1 = %{operator: :eq, left: ref(:status), right: %{value: "active"}}
      f2 = %{operator: :>=, left: ref(:age), right: %{value: 18}}
      f3 = %{operator: :in, left: ref(:role), right: %{value: ["admin", "user"]}}

      {sql, params} = where([f1, f2, f3])

      assert sql ==
               " WHERE `status` = ? AND `age` >= ? AND `role` IN (?, ?)"

      assert params == ["active", 18, "admin", "user"]
    end

    test "mixed comparison and LIKE operators combine cleanly" do
      eq = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      sw = %{operator: :starts_with, left: ref(:name), right: %{value: "a"}}
      ew = %{operator: :ends_with, left: ref(:name), right: %{value: "z"}}
      contains = %{operator: :contains, left: ref(:name), right: %{value: "oh"}}
      nil_true = %{operator: :is_nil, left: ref(:deleted_at), right: %{value: true}}

      {sql, params} = where([eq, sw, ew, contains, nil_true])

      assert String.contains?(sql, "`a` = ?")
      assert String.contains?(sql, "`name` LIKE ?")
      assert String.contains?(sql, "positionCaseInsensitive(`name`, ?) > 0")
      assert String.contains?(sql, "`deleted_at` IS NULL")
      assert params == [1, "a%", "%z", "oh"]
    end
  end

  describe "full SELECT assembly" do
    test "select + distinct + where + group + order + limit + offset" do
      f1 = %{operator: :eq, left: ref(:status), right: %{value: "active"}}
      f2 = %{operator: :>=, left: ref(:age), right: %{value: 18}}

      {sql, params} =
        QueryBuilder.build_optimized_query(
          query(%{
            database: "app",
            filters: [f1, f2],
            group_by: [:status],
            distinct: [:status],
            select: [:status, :age],
            sorts: [{:age, :desc}, {:status, :asc}],
            limit: 20,
            offset: 10
          })
        )

      assert sql ==
               "SELECT DISTINCT `status` FROM `app`.`users` WHERE `status` = ? AND `age` >= ? GROUP BY `status` ORDER BY `age` DESC, `status` ASC LIMIT 20 OFFSET 10"

      assert params == ["active", 18]
    end

    test "default sort direction is ASC when only an atom is given" do
      {sql, _} =
        QueryBuilder.build_optimized_query(query(%{sorts: [:name, {:age, :desc}]}))

      assert String.contains?(sql, "ORDER BY `name` ASC, `age` DESC")
    end

    test "empty sorts produce no ORDER BY clause" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{sorts: []}))
      refute String.contains?(sql, "ORDER BY")
    end
  end

  describe "get_filter_columns/1" do
    test "collects columns from a deep tree without duplicates" do
      a = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      b = %{operator: :eq, left: ref(:b), right: %{value: 2}}
      c = %{operator: :eq, left: ref(:a), right: %{value: 3}}
      tree = %{op: :or, left: %{op: :and, left: a, right: b}, right: c}

      cols = QueryBuilder.get_filter_columns([tree])
      assert Enum.sort(cols) == [:a, :b]
    end

    test "collects columns from NOT nodes" do
      child = %{operator: :eq, left: ref(:x), right: %{value: 1}}
      tree = %Ash.Query.Not{expression: child}
      assert QueryBuilder.get_filter_columns([tree]) == [:x]
    end
  end

  describe "untranslatable filters in complex trees" do
    test "a bad leaf inside a deep tree makes the whole WHERE clause empty (and warns)" do
      good = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      bad = %{operator: :unknown_op, left: ref(:b), right: %{value: 2}}
      tree = %{op: :and, left: good, right: bad}

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert where([tree]) == {"", []}
             end) =~ "dropping untranslatable filter"
    end
  end
end
