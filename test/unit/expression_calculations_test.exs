defmodule AshClickhouse.ExpressionCalculationsTest do
  @moduledoc """
  Coverage for the expression calculations the data layer evaluates.

  An expression calculation is a value derived from a resource's own
  attributes by an expression rather than stored. The data layer pushes the
  expression into the ClickHouse `SELECT` list so the database computes it,
  and the result is reported on the record's `calculations` map.
  """
  use ExUnit.Case, async: false

  alias Ash.Query.Calculation
  alias AshClickhouse.CompatCustomer
  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.FakeRepo

  setup do
    {:ok, _pid} = FakeRepo.start()
    FakeRepo.reset()
    on_exit(&FakeRepo.reset/0)

    :ok
  end

  describe "the select list can carry an expression" do
    test "a plain column renders as its quoted name" do
      {sql, _params} =
        QueryBuilder.build_optimized_query(%AshClickhouse.Query{
          table: "users",
          select: [:id, :name]
        })

      assert sql == "SELECT `id`, `name` FROM `users`"
    end

    test "an expression renders as <sql> AS <quoted name>" do
      {sql, _params} =
        QueryBuilder.build_optimized_query(%AshClickhouse.Query{
          table: "users",
          select: [:id, {:copied_name, "CAST(`name` AS String)"}]
        })

      assert sql == "SELECT `id`, CAST(`name` AS String) AS `copied_name` FROM `users`"
    end
  end

  describe "the value expression translator" do
    test "a typed column reference is rendered as a cast" do
      expression = %Ash.Query.Function.Type{
        arguments: [
          %Ash.Query.Ref{attribute: :name, relationship_path: []},
          Ash.Type.String,
          []
        ]
      }

      assert {"CAST(`name` AS String)", []} = QueryBuilder.build_value_expression(expression)
    end

    test "an arithmetic expression binds its literal as a parameter" do
      expression = %Ash.Query.Function.Type{
        arguments: [
          %Ash.Query.Call{
            name: :*,
            args: [
              %Ash.Query.Ref{attribute: :age, relationship_path: []},
              2
            ],
            operator?: true
          },
          Ash.Type.Integer,
          []
        ]
      }

      assert {"CAST((`age` * ?) AS Int64)", [{nil, 2}]} =
               QueryBuilder.build_value_expression(expression)
    end

    test "an expression that cannot be rendered returns nil" do
      assert nil == QueryBuilder.build_value_expression(%{not: :an_expression})
    end
  end

  describe "add_calculations/3" do
    test "a translatable calculation gains an aliased expression in the select list" do
      q = DataLayer.resource_to_query(CompatCustomer, nil)

      calculation = %Ash.Query.Calculation{
        name: :copied_name,
        module: Ash.Resource.Calculation.Expression,
        opts: [expr: :name],
        type: Ash.Type.String
      }

      expression = %Ash.Query.Function.Type{
        arguments: [
          %Ash.Query.Ref{attribute: :name, relationship_path: []},
          Ash.Type.String,
          []
        ]
      }

      {:ok, q2} = DataLayer.add_calculations(q, [{calculation, expression}], CompatCustomer)

      assert {:copied_name, sql} = List.last(q2.select)
      assert sql == "CAST(`name` AS String)"
    end

    test "an untranslatable calculation is recorded for evaluation against the record" do
      q = DataLayer.resource_to_query(CompatCustomer, nil)

      calculation = %Ash.Query.Calculation{
        name: :copied_name,
        module: Ash.Resource.Calculation.Expression,
        opts: [expr: :name],
        type: Ash.Type.String
      }

      {:ok, q2} =
        DataLayer.add_calculations(q, [{calculation, %{not: :renderable}}], CompatCustomer)

      assert q2.select == nil
      assert [entry] = q2.context.calculations
      assert entry.name == :copied_name
    end
  end

  describe "the decode path" do
    test "a result column carrying a calculation lands in the record's calculations map" do
      record =
        AshClickhouse.DataLayer.Record.to_ash_record(
          ["id-1", "alice", "alice@example.com", 30, "gold", "alice"],
          CompatCustomer,
          [:id, :name, :email, :age, :tier, {:copied_name, "CAST(`name` AS String)"}],
          %{"copied_name" => %{name: :copied_name, type: Ash.Type.String}}
        )

      assert record.calculations.copied_name == "alice"
      assert record.name == "alice"
      assert record.age == 30
    end

    test "a numeric calculation decodes to a number rather than a string" do
      record =
        AshClickhouse.DataLayer.Record.to_ash_record(
          ["id-1", "alice", "alice@example.com", 30, "gold", "60"],
          CompatCustomer,
          [:id, :name, :email, :age, :tier, {:doubled_age, "CAST((`age` * 2) AS Int64)"}],
          %{"doubled_age" => %{name: :doubled_age, type: Ash.Type.Integer}}
        )

      assert record.calculations.doubled_age == 60
    end
  end

  describe "sorting by an expression calculation" do
    test "the layer reports expression calculation sorting as supported" do
      assert DataLayer.can?(CompatCustomer, :expression_calculation_sort)
    end

    test "the calculation is projected into the select list and ordered by its alias" do
      q = DataLayer.resource_to_query(CompatCustomer, nil)

      calculation = %Ash.Query.Calculation{
        name: :copied_name,
        module: Ash.Resource.Calculation.Expression,
        opts: [expr: %Ash.Query.Ref{attribute: :name, relationship_path: []}],
        type: Ash.Type.String
      }

      {:ok, q2} = DataLayer.sort(q, [{calculation, :asc}], CompatCustomer)

      assert {calculation.name, :asc} in q2.sorts
      assert {:copied_name, _sql} = List.last(q2.select)

      {sql, _params} = QueryBuilder.build_optimized_query(q2)
      assert sql =~ "ORDER BY `copied_name` ASC"
    end

    test "a read sorted by an expression calculation is valid and orders by the alias" do
      FakeRepo.default_response([
        ["id-1", "alice", "alice@example.com", 30, "gold", "alice"]
      ])

      calculation =
        Calculation.from_resource_calculation!(CompatCustomer, :copied_name)

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:copied_name)
        |> Ash.Query.sort(calculation)

      assert query.valid?

      assert {:ok, [record]} = Ash.read(query)
      assert record.calculations.copied_name == "alice"

      assert [sql] = FakeRepo.queries()
      assert sql =~ "ORDER BY `copied_name`"
    end
  end

  describe "reading a resource with an expression calculation" do
    test "the read completes and returns records" do
      FakeRepo.default_response([
        ["id-1", "alice", "alice@example.com", 30, "gold", "alice"]
      ])

      query = Ash.Query.new(CompatCustomer) |> Ash.Query.load(:copied_name)

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"
    end

    test "the calculated value is present on the returned record" do
      FakeRepo.default_response([
        ["id-1", "alice", "alice@example.com", 30, "gold", "alice"]
      ])

      query = Ash.Query.new(CompatCustomer) |> Ash.Query.load(:copied_name)

      assert {:ok, [record]} = Ash.read(query)
      assert record.calculations.copied_name == "alice"
    end

    test "the calculated value reflects the stored attribute" do
      FakeRepo.default_response([
        ["id-1", "alice", "alice@example.com", 30, "gold", "alice"]
      ])

      query = Ash.Query.new(CompatCustomer) |> Ash.Query.load(:copied_name)

      assert {:ok, [record]} = Ash.read(query)
      assert record.calculations.copied_name == record.name
    end

    test "a numeric calculation returns a number rather than a string" do
      FakeRepo.default_response([
        ["id-1", "alice", "alice@example.com", 30, "gold", "60"]
      ])

      query = Ash.Query.new(CompatCustomer) |> Ash.Query.load(:doubled_age)

      assert {:ok, [record]} = Ash.read(query)
      assert record.calculations.doubled_age == 60
      assert is_integer(record.calculations.doubled_age)
    end

    test "several expression calculations are evaluated together, in one query" do
      FakeRepo.default_response([
        ["id-1", "alice", "alice@example.com", 30, "gold", "alice", "60"]
      ])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.load(:copied_name)
        |> Ash.Query.load(:doubled_age)

      assert {:ok, [record]} = Ash.read(query)
      assert record.calculations.copied_name == "alice"
      assert record.calculations.doubled_age == 60
      assert FakeRepo.query_count() == 1
    end
  end
end
