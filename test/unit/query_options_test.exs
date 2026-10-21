defmodule AshClickhouse.QueryOptionsTest do
  @moduledoc """
  Coverage for the query-level options the layer honours — the distinct sort,
  the query timeout, and the bulk write batch size.
  """
  use ExUnit.Case, async: false

  import Ash.Query

  alias AshClickhouse.CompatCustomer
  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.FakeRepo
  alias AshClickhouse.Query

  @customer_row ["id-1", "alice", "alice@example.com", 30, "gold"]

  setup do
    {:ok, _pid} = FakeRepo.start()
    FakeRepo.reset()
    on_exit(&FakeRepo.reset/0)

    :ok
  end

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
          group_by: nil,
          distinct_sort: []
        },
        overrides
      )
    )
  end

  describe "the distinct sort" do
    test "the layer reports a distinct sort as supported" do
      assert DataLayer.can?(CompatCustomer, :distinct_sort)
    end

    test "distinct_sort/3 stores the sort on the query" do
      q = DataLayer.resource_to_query(CompatCustomer, nil)

      {:ok, q2} = DataLayer.distinct_sort(q, [{:name, :asc}], CompatCustomer)

      assert q2.distinct_sort == [{:name, :asc}]
    end

    test "the rendered statement carries the GROUP BY and LIMIT 1 BY clauses" do
      {sql, _params} =
        QueryBuilder.build_optimized_query(
          query(%{
            select: [:id, :name],
            distinct: [:name],
            distinct_sort: [{:name, :asc}]
          })
        )

      assert sql =~ "GROUP BY `name`"
      assert sql =~ "LIMIT 1 BY `name`"
    end

    test "the requested sort drives the ORDER BY" do
      {sql, _params} =
        QueryBuilder.build_optimized_query(
          query(%{
            select: [:id, :name],
            distinct: [:name],
            distinct_sort: [{:name, :desc}]
          })
        )

      assert sql =~ "ORDER BY `name` DESC"
    end

    test "the columns that are not grouped are aggregated over the sort key" do
      {sql, _params} =
        QueryBuilder.build_optimized_query(
          query(%{
            select: [:id, :name, :age],
            distinct: [:name],
            distinct_sort: [{:age, :asc}]
          })
        )

      assert sql =~ "argMin(`id`, `age`)"
      assert sql =~ "argMin(`age`, `age`)"
    end
  end

  describe "reading with a distinct sort" do
    test "the query is valid and returns one record per distinct value" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.distinct([:name])
        |> Ash.Query.distinct_sort(name: :asc)

      assert query.valid?

      assert {:ok, [record]} = Ash.read(query)
      assert record.name == "alice"
    end

    test "the statement selects one record per distinct value" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.new(CompatCustomer)
        |> Ash.Query.distinct([:name])
        |> Ash.Query.distinct_sort(name: :desc)

      assert {:ok, [_record]} = Ash.read(query)

      assert [sql] = FakeRepo.queries()
      assert sql =~ "GROUP BY `name`"
      assert sql =~ "LIMIT 1 BY `name`"
      assert sql =~ "ORDER BY `name` DESC"
    end
  end

  describe "the query timeout" do
    test "the layer reports a timeout as supported" do
      assert DataLayer.can?(CompatCustomer, :timeout)
    end

    test "a timeout is accepted rather than refused" do
      query = Ash.Query.new(CompatCustomer) |> Ash.Query.timeout(5_000)

      assert query.valid?
      assert query.timeout == 5_000
    end

    test "the timeout is carried on the request" do
      FakeRepo.default_response([@customer_row])

      query = Ash.Query.set_context(Ash.Query.new(CompatCustomer), %{timeout: 5_000})

      assert {:ok, [_record]} = Ash.read(query)

      assert [opts] = FakeRepo.query_opts()
      assert opts[:settings][:max_execution_time] == 5
    end

    test "the timeout is rounded up to the next second" do
      FakeRepo.default_response([@customer_row])

      query = Ash.Query.set_context(Ash.Query.new(CompatCustomer), %{timeout: 1_001})

      assert {:ok, [_record]} = Ash.read(query)

      assert [opts] = FakeRepo.query_opts()
      assert opts[:settings][:max_execution_time] == 2
    end

    test "the mutations_sync setting is preserved when both are present" do
      FakeRepo.default_response([@customer_row])

      query =
        Ash.Query.set_context(Ash.Query.new(CompatCustomer), %{
          timeout: 5_000,
          mutations_sync: 2
        })

      assert {:ok, [_record]} = Ash.read(query)

      assert [opts] = FakeRepo.query_opts()
      assert opts[:settings][:mutations_sync] == 2
      assert opts[:settings][:max_execution_time] == 5
    end

    test "a query that exceeds its timeout fails rather than returning a result" do
      FakeRepo.fail_next(%RuntimeError{message: "Timeout exceeded: elapsed"})

      query = Ash.Query.set_context(Ash.Query.new(CompatCustomer), %{timeout: 1})

      assert {:error, _error} = Ash.read(query)
    end
  end

  describe "the bulk write batch size" do
    test "the layer reports the size it writes rows in" do
      assert DataLayer.default_bulk_batch_size(CompatCustomer, :create) == 1000
    end

    test "a bulk write of more rows than the reported size sends the rows in groups of that size" do
      size = DataLayer.default_bulk_batch_size(CompatCustomer, :create)

      inputs = for index <- 1..(size + 1), do: %{name: "user-#{index}"}

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_create(inputs, CompatCustomer, :create, return_records?: false)

      assert insert_batch_sizes() == [size, 1]
    end

    test "a caller-specified batch size takes precedence" do
      inputs = for index <- 1..25, do: %{name: "user-#{index}"}

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_create(inputs, CompatCustomer, :create,
                 return_records?: false,
                 batch_size: 10
               )

      assert insert_batch_sizes() == [10, 10, 5]
    end
  end

  defp insert_batch_sizes do
    FakeRepo.calls()
    |> Enum.filter(&match?({:insert_rows, _statement, _rows}, &1))
    |> Enum.map(fn {:insert_rows, _statement, rows} -> rows end)
  end
end
