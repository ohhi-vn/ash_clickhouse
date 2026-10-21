defmodule AshClickhouse.FilterExpressionsTest do
  @moduledoc """
  Coverage for the translation of Ash's *concrete* filter expression shapes —
  the `%Ash.Query.Operator.*` structs and the `%Ash.Query.Function.*` structs —
  into ClickHouse predicates, and for the capability the layer reports for
  them.

  The legacy `{op, name, right}` map shape is still produced by
  `set_tenant/3` (attribute-based multitenancy), so it must keep reaching the
  same translation as the modern struct shapes.
  """
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer
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

  defp where(filter), do: QueryBuilder.build_where_clause([filter])

  defp ref(name), do: %Ash.Query.Ref{attribute: name, relationship_path: []}

  describe "operator structs normalise to a shared (operator, left, right) triple" do
    test "the concrete Ash operator structs are recognised" do
      assert {:ok, :eq, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.Eq{left: ref(:a), right: 1})

      assert {:ok, :not_eq, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.NotEq{
                 left: ref(:a),
                 right: 1
               })

      assert {:ok, :>, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.GreaterThan{
                 left: ref(:a),
                 right: 1
               })

      assert {:ok, :>=, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.GreaterThanOrEqual{
                 left: ref(:a),
                 right: 1
               })

      assert {:ok, :<, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.LessThan{
                 left: ref(:a),
                 right: 1
               })

      assert {:ok, :<=, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.LessThanOrEqual{
                 left: ref(:a),
                 right: 1
               })

      assert {:ok, :in, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.In{
                 left: ref(:a),
                 right: [1]
               })

      assert {:ok, :is_nil, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.IsNil{
                 left: ref(:a),
                 right: true
               })

      assert {:ok, :has, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.Has{left: ref(:a), right: 1})

      assert {:ok, :overlaps, _left, _right} =
               QueryBuilder.normalize_expression(%Ash.Query.Operator.Overlaps{
                 left: ref(:a),
                 right: [1]
               })
    end

    test "the legacy map shape normalises to the same triple" do
      assert {:ok, :eq, :a, 1} =
               QueryBuilder.normalize_expression(%{op: :eq, name: :a, right: 1})

      assert {:ok, :eq, :a, 1} =
               QueryBuilder.normalize_expression(%{operator: :eq, left: :a, right: 1})
    end

    test "an unknown expression does not normalise" do
      assert :error == QueryBuilder.normalize_expression(:not_an_expression)
      assert :error == QueryBuilder.normalize_expression(%{name: :a})
    end
  end

  describe "the legacy and modern shapes reach the same translation" do
    test "an equality filter translates the same either way" do
      legacy = where(%{op: :eq, name: :name, right: "x"})
      modern = where(%Ash.Query.Operator.Eq{left: ref(:name), right: "x"})

      assert legacy == modern
      assert legacy == {" WHERE `name` = ?", ["x"]}
    end

    test "the legacy tenant filter shape still translates" do
      assert where(%{name: :tenant_id, op: :eq, right: %{value: "t1"}}) ==
               {" WHERE `tenant_id` = ?", ["t1"]}
    end
  end

  describe "string inequality is translated" do
    test "the != operator produces an inequality predicate" do
      assert where(%Ash.Query.Operator.NotEq{left: ref(:name), right: "bob"}) ==
               {" WHERE `name` != ?", ["bob"]}
    end

    test "the literal is bound as a parameter, not interpolated into the SQL" do
      {sql, params} = where(%Ash.Query.Operator.NotEq{left: ref(:name), right: "bob"})

      refute sql =~ "bob"
      assert params == ["bob"]
    end

    test "the legacy :not_eq spelling still translates" do
      assert where(%{op: :not_eq, name: :name, right: "bob"}) == {" WHERE `name` != ?", ["bob"]}
    end

    test "the :!= operator atom translates" do
      assert where(%{operator: :!=, left: ref(:name), right: "bob"}) ==
               {" WHERE `name` != ?", ["bob"]}
    end
  end

  describe "function-shaped filters are translated" do
    test "contains becomes a substring search" do
      {sql, params} =
        where(%Ash.Query.Function.Contains{arguments: [ref(:name), "bo"]})

      assert sql == " WHERE positionCaseInsensitive(`name`, ?) > 0"
      assert params == ["bo"]
    end

    test "contains honours the case_sensitive_contains setting" do
      Application.put_env(:ash_clickhouse, :case_sensitive_contains, true)
      on_exit(fn -> Application.delete_env(:ash_clickhouse, :case_sensitive_contains) end)

      {sql, params} = where(%Ash.Query.Function.Contains{arguments: [ref(:name), "bo"]})

      assert sql == " WHERE position(`name`, ?) > 0"
      assert params == ["bo"]
    end

    test "string_starts_with becomes a LIKE with escaped wildcards" do
      {sql, params} =
        where(%Ash.Query.Function.StringStartsWith{arguments: [ref(:name), "50% off"]})

      assert sql == " WHERE `name` LIKE ? ESCAPE '\\'"
      assert params == ["50\\% off%"]
    end

    test "string_ends_with becomes a LIKE with escaped wildcards" do
      {sql, params} =
        where(%Ash.Query.Function.StringEndsWith{arguments: [ref(:name), "a_b"]})

      assert sql == " WHERE `name` LIKE ? ESCAPE '\\'"
      assert params == ["%a\\_b"]
    end

    test "has becomes ClickHouse's has()" do
      {sql, params} = where(%Ash.Query.Function.Has{arguments: [ref(:tags), "a"]})

      assert sql == " WHERE has(`tags`, ?)"
      assert params == ["a"]
    end

    test "intersects becomes arrayIntersect over the two columns" do
      {sql, params} =
        where(%Ash.Query.Function.Intersects{arguments: [ref(:tags), ref(:other_tags)]})

      assert sql == " WHERE notEmpty(arrayIntersect(`tags`, `other_tags`))"
      assert params == []
    end

    test "the null-test function becomes the null comparison" do
      {sql, params} = where(%Ash.Query.Function.IsNil{arguments: [ref(:email)]})

      assert sql == " WHERE `email` IS NULL"
      assert params == []
    end

    test "the null-test operator becomes the null comparison" do
      assert where(%Ash.Query.Operator.IsNil{left: ref(:email), right: true}) ==
               {" WHERE `email` IS NULL", []}

      assert where(%Ash.Query.Operator.IsNil{left: ref(:email), right: false}) ==
               {" WHERE `email` IS NOT NULL", []}
    end
  end

  describe "the layer reports exactly the filter expressions it can express" do
    test "a supported operator is reported as supported" do
      assert DataLayer.can?(
               AshClickhouse.TestResource,
               {:filter_expr, %Ash.Query.Operator.Eq{left: ref(:name), right: "x"}}
             )
    end

    test "a supported function is reported as supported" do
      assert DataLayer.can?(
               AshClickhouse.TestResource,
               {:filter_expr, %Ash.Query.Function.Contains{arguments: [ref(:name), "x"]}}
             )
    end

    test "an unsupported expression is reported as unsupported" do
      refute DataLayer.can?(
               AshClickhouse.TestResource,
               {:filter_expr, %Ash.Query.Function.Round{arguments: [ref(:age), 2]}}
             )
    end

    test "the capability and the translator share one table" do
      supported = [
        %Ash.Query.Operator.Eq{left: ref(:a), right: 1},
        %Ash.Query.Operator.NotEq{left: ref(:a), right: 1},
        %Ash.Query.Operator.GreaterThan{left: ref(:a), right: 1},
        %Ash.Query.Operator.GreaterThanOrEqual{left: ref(:a), right: 1},
        %Ash.Query.Operator.LessThan{left: ref(:a), right: 1},
        %Ash.Query.Operator.LessThanOrEqual{left: ref(:a), right: 1},
        %Ash.Query.Operator.In{left: ref(:a), right: [1]},
        %Ash.Query.Operator.IsNil{left: ref(:a), right: true},
        %Ash.Query.Operator.Has{left: ref(:a), right: 1},
        %Ash.Query.Operator.Overlaps{left: ref(:a), right: [1]},
        %Ash.Query.Function.Contains{arguments: [ref(:a), "x"]},
        %Ash.Query.Function.StringStartsWith{arguments: [ref(:a), "x"]},
        %Ash.Query.Function.StringEndsWith{arguments: [ref(:a), "x"]},
        %Ash.Query.Function.IsNil{arguments: [ref(:a)]},
        %Ash.Query.Function.Has{arguments: [ref(:a), "x"]},
        %Ash.Query.Function.Intersects{arguments: [ref(:a), ref(:b)]}
      ]

      for expr <- supported do
        assert DataLayer.can?(AshClickhouse.TestResource, {:filter_expr, expr}),
               "expected #{inspect(expr.__struct__)} to be reported as supported"

        assert {_sql, _params} = where(expr)
      end
    end
  end

  describe "the layer publishes the ClickHouse functions available in filters" do
    test "a published function is translated into its ClickHouse equivalent" do
      function = %AshClickhouse.Functions.Match{
        arguments: [
          %Ash.Query.Ref{attribute: :name, relationship_path: []},
          "^John"
        ]
      }

      {sql, params} = where(function)

      assert sql == " WHERE match(`name`, ?)"
      assert params == ["^John"]
    end
  end

  describe "the full statement still renders" do
    test "a filter over a query builds the expected statement" do
      filter = %Ash.Query.Operator.NotEq{left: ref(:name), right: "bob"}

      {sql, params} =
        QueryBuilder.build_optimized_query(query(%{filters: [filter], select: [:id, :name]}))

      assert sql == "SELECT `id`, `name` FROM `users` WHERE `name` != ?"
      assert params == ["bob"]
    end
  end
end
