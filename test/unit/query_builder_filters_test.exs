defmodule AshClickhouse.QueryBuilderFiltersTest do
  @moduledoc """
  Exhaustive coverage of filter translation in `AshClickhouse.DataLayer.QueryBuilder`.

  These tests assert that every supported Ash filter operator either translates
  to a SQL fragment or is explicitly untranslatable (and therefore warned/raised
  about rather than silently dropped — see item #1 in the review).
  """
  use ExUnit.Case, async: false

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

  # Builds a single-filter WHERE clause and returns {sql, params}.
  defp where(filter), do: QueryBuilder.build_where_clause([filter])

  defp ref(name), do: %{name: name}

  describe "every supported comparison operator translates" do
    test "eq / ==" do
      assert where(%{operator: :eq, left: ref(:a), right: %{value: 1}}) == {" WHERE `a` = ?", [1]}
      assert where(%{operator: :==, left: ref(:a), right: %{value: 1}}) == {" WHERE `a` = ?", [1]}
    end

    test "not_eq" do
      assert where(%{operator: :not_eq, left: ref(:a), right: %{value: 1}}) ==
               {" WHERE `a` != ?", [1]}
    end

    test ">, >=, <, <=" do
      assert where(%{operator: :>, left: ref(:a), right: %{value: 1}}) == {" WHERE `a` > ?", [1]}

      assert where(%{operator: :>=, left: ref(:a), right: %{value: 1}}) ==
               {" WHERE `a` >= ?", [1]}

      assert where(%{operator: :<, left: ref(:a), right: %{value: 1}}) == {" WHERE `a` < ?", [1]}

      assert where(%{operator: :<=, left: ref(:a), right: %{value: 1}}) ==
               {" WHERE `a` <= ?", [1]}
    end

    test "in / not_in with list" do
      assert where(%{operator: :in, left: ref(:a), right: %{value: [1, 2]}}) ==
               {" WHERE `a` IN (?, ?)", [1, 2]}

      assert where(%{operator: :not_in, left: ref(:a), right: %{value: [1, 2]}}) ==
               {" WHERE `a` NOT IN (?, ?)", [1, 2]}
    end

    test "in with single value" do
      assert where(%{operator: :in, left: ref(:a), right: %{value: 1}}) ==
               {" WHERE `a` IN (?)", [1]}
    end

    test "is_nil true / false" do
      assert where(%{operator: :is_nil, left: ref(:a), right: %{value: true}}) ==
               {" WHERE `a` IS NULL", []}

      assert where(%{operator: :is_nil, left: ref(:a), right: %{value: false}}) ==
               {" WHERE `a` IS NOT NULL", []}
    end
  end

  describe "LIKE pattern escaping (item #3)" do
    test "starts_with escapes wildcards and appends %" do
      {sql, [param]} =
        where(%{operator: :starts_with, left: ref(:name), right: %{value: "50% off"}})

      assert sql == " WHERE `name` LIKE ? ESCAPE '\\'"
      assert param == "50\\% off%"
    end

    test "ends_with escapes wildcards and prepends %" do
      {sql, [param]} = where(%{operator: :ends_with, left: ref(:name), right: %{value: "a_b"}})
      assert sql == " WHERE `name` LIKE ? ESCAPE '\\'"
      assert param == "%a\\_b"
    end

    test "contains is case-insensitive and treats %/_ literally" do
      {sql, [param]} = where(%{operator: :contains, left: ref(:name), right: %{value: "50% off"}})
      assert sql == " WHERE positionCaseInsensitive(`name`, ?) > 0"
      assert param == "50% off"
    end

    test "escape char itself is escaped" do
      {_sql, [param]} =
        where(%{operator: :starts_with, left: ref(:name), right: %{value: "a\\b"}})

      assert param == "a\\\\b%"
    end
  end

  describe "logical operators" do
    test "and / or combine children" do
      left = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      right = %{operator: :eq, left: ref(:b), right: %{value: 2}}

      assert where(%{op: :and, left: left, right: right}) ==
               {" WHERE (`a` = ? AND `b` = ?)", [1, 2]}

      assert where(%{op: :or, left: left, right: right}) ==
               {" WHERE (`a` = ? OR `b` = ?)", [1, 2]}
    end

    test "not negates a child (Ash.Query.Not)" do
      child = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      assert where(%Ash.Query.Not{expression: child}) == {" WHERE (NOT `a` = ?)", [1]}
    end

    test "not negates a child (BooleanExpression)" do
      child = %{operator: :eq, left: ref(:a), right: %{value: 1}}

      assert where(%Ash.Query.BooleanExpression{op: :not, left: child, right: nil}) ==
               {" WHERE (NOT `a` = ?)", [1]}
    end
  end

  describe "untranslatable filters are surfaced, not silently dropped (item #1)" do
    test "a malformed filter shape produces no predicate and is reported" do
      # Capture the warning that build_where_clause emits for an untranslatable
      # filter. The filter is dropped from the SQL (no row leak), but a warning
      # is logged so the gap is visible.
      filter = %{operator: :unknown_op, left: ref(:a), right: %{value: 1}}

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert where(filter) == {"", []}
             end) =~ "dropping untranslatable filter"
    end

    test "when raise_on_untranslatable_filter is enabled, an unknown filter raises" do
      filter = %{operator: :unknown_op, left: ref(:a), right: %{value: 1}}

      Application.put_env(:ash_clickhouse, :raise_on_untranslatable_filter, true)

      try do
        assert_raise AshClickhouse.Error.QueryError, fn ->
          where(filter)
        end
      after
        Application.delete_env(:ash_clickhouse, :raise_on_untranslatable_filter)
      end
    end

    test "an untranslatable child makes the whole conjunction untranslatable" do
      good = %{operator: :eq, left: ref(:a), right: %{value: 1}}
      bad = %{operator: :unknown_op, left: ref(:a), right: %{value: 1}}

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert where(%{op: :and, left: good, right: bad}) == {"", []}
             end) =~ "dropping untranslatable filter"
    end
  end

  describe "limit/offset are validated integers (item #4)" do
    test "integer limit/offset interpolate as integers" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{limit: 10, offset: 5}))
      assert sql == "SELECT * FROM `users` LIMIT 10 OFFSET 5"
    end

    test "non-integer limit raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        QueryBuilder.build_optimized_query(query(%{limit: "10; DROP TABLE users"}))
      end
    end

    test "non-integer offset raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        QueryBuilder.build_optimized_query(query(%{offset: "evil"}))
      end
    end

    test "numeric string limit is coerced to an integer" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{limit: "10"}))
      assert sql == "SELECT * FROM `users` LIMIT 10"
    end
  end
end
