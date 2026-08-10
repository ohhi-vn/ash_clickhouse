defmodule AshClickhouse.AggregateTest do
  @moduledoc "Unit tests for AshClickhouse.DataLayer.Aggregate edge paths."
  use ExUnit.Case, async: false

  alias AshClickhouse.DataLayer.Aggregate
  alias AshClickhouse.DataLayer.Types

  defmodule FakeDomain do
    use Ash.Domain

    resources do
      resource(UserResource)
      resource(TeamResource)
      resource(MemberResource)
      resource(CompositeResource)
      resource(CompositeTeamResource)
      resource(CompositeMemberResource)
    end
  end

  defmodule UserResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.AggregateTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("users")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:age, :integer)
    end
  end

  defmodule TeamResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.AggregateTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("teams")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  defmodule MemberResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.AggregateTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("members")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:team_id, :string)
    end

    relationships do
      belongs_to(:team, TeamResource)
    end
  end

  defmodule CompositeResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.AggregateTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("composite")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:code, :string, primary_key?: true, allow_nil?: false)
    end
  end

  defmodule CompositeTeamResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.AggregateTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("composite_teams")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:code, :string, primary_key?: true, allow_nil?: false)
    end
  end

  defmodule CompositeMemberResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.AggregateTest.FakeDomain

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("composite_members")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:team_id, :string)
    end

    relationships do
      belongs_to(:team, CompositeTeamResource)
    end
  end

  # ── Fake repos ────────────────────────────────────────────────────────────────

  defmodule OkRepo do
    def query(_sql, _params, _opts) do
      {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [["7"]], columns: ["result"]}}
    end
  end

  defmodule BatchRepo do
    def query(_sql, _params, _opts) do
      {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [["t1", "7"]], columns: ["id", "result"]}}
    end
  end

  defmodule UuidBatchRepo do
    def query(_sql, _params, _opts) do
      {:ok,
       %ClickHouse.Result{
         raw: "",
         meta: %{},
         compressed: false,
         rows: [[uuid_bin(), "5"]],
         columns: ["id", "result"]
       }}
    end

    defp uuid_bin do
      {:ok, bin} = Types.uuid_string_to_binary("123e4567-e89b-12d3-a456-426614174000")
      bin
    end
  end

  defmodule MedianRepo do
    def query(_sql, _params, _opts) do
      {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [["id-1", "7"]], columns: ["id", "result"]}}
    end
  end

  defmodule ErrRepo do
    def query(_sql, _params, _opts), do: {:error, %RuntimeError{message: "db down"}}
  end

  # ── run/6 ─────────────────────────────────────────────────────────────────────

  describe "run/6 query building and decoding" do
    test "runs COUNT with a field" do
      result =
        Aggregate.run(
          [%{kind: :count, name: :cnt, field: :age, resource: UserResource}],
          UserResource,
          OkRepo,
          "`users`",
          "",
          []
        )

      assert result.cnt == 7
    end

    test "runs SUM with a nil field (aggregates * )" do
      result =
        Aggregate.run(
          [%{kind: :sum, name: :s, field: nil, resource: UserResource}],
          UserResource,
          OkRepo,
          "`users`",
          "",
          []
        )

      assert result.s == 7.0
    end

    test "runs SUM with a %{name: field} map" do
      result =
        Aggregate.run(
          [%{kind: :sum, name: :s, field: %{name: :age}, resource: UserResource}],
          UserResource,
          OkRepo,
          "`users`",
          "",
          []
        )

      assert result.s == 7
    end

    test "runs SUM with a string field" do
      result =
        Aggregate.run(
          [%{kind: :sum, name: :s, field: "age", resource: UserResource}],
          UserResource,
          OkRepo,
          "`users`",
          "",
          []
        )

      assert result.s == 7.0
    end

    test "halts with the repo error when a query fails" do
      assert {:error, %RuntimeError{message: "db down"}} =
               Aggregate.run(
                 [%{kind: :count, name: :cnt, field: nil, resource: UserResource}],
                 UserResource,
                 ErrRepo,
                 "`users`",
                 "",
                 []
               )
    end
  end

  # ── attach/5 ──────────────────────────────────────────────────────────────────

  describe "attach/5 edge paths" do
    test "returns records unchanged when the repo is nil" do
      records = [struct(UserResource, id: "1", age: 30)]
      agg = %{kind: :count, name: :c, field: nil, relationship_path: [], resource: UserResource}
      assert Aggregate.attach(records, [agg], UserResource, nil, []) == records
    end

    test "composite pk same-table aggregate falls back to default_value" do
      records = [struct(CompositeResource, id: "1", code: "a")]
      agg = %{kind: :count, name: :c, field: nil, relationship_path: [], resource: CompositeResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], CompositeResource, OkRepo, [])
      assert record.aggregates[:c] == 0
    end

    test "multi-hop relationship path falls back to default_value" do
      records = [struct(UserResource, id: "1", age: 30)]
      agg = %{kind: :count, name: :c, field: nil, relationship_path: [:a, :b], resource: UserResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], UserResource, OkRepo, [])
      assert record.aggregates[:c] == 0
    end

    test "belongs_to with a composite-pk related resource falls back to default_value" do
      records = [struct(CompositeMemberResource, id: "m1", team_id: "t1")]
      agg = %{kind: :count, name: :c, field: nil, relationship_path: [:team], resource: CompositeMemberResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], CompositeMemberResource, OkRepo, [])
      assert record.aggregates[:c] == 0
    end

    test "belongs_to with a single-pk related resource batches a query" do
      records = [struct(MemberResource, id: "m1", team_id: "t1")]
      agg = %{kind: :count, name: :c, field: nil, relationship_path: [:team], resource: MemberResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], MemberResource, BatchRepo, [])
      assert record.aggregates[:c] == 7
    end

    test "unknown aggregate kind falls through to the raw value" do
      records = [struct(UserResource, id: "id-1", age: 30)]
      agg = %{kind: :median, name: :m, field: :age, relationship_path: [], resource: UserResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], UserResource, MedianRepo, [])
      assert record.aggregates[:m] == "7"
    end

    test "normalizes a 16-byte uuid key from the batched query" do
      records = [struct(UserResource, id: "123e4567-e89b-12d3-a456-426614174000", age: 30)]
      agg = %{kind: :sum, name: :s, field: :age, relationship_path: [], resource: UserResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], UserResource, UuidBatchRepo, [])
      assert record.aggregates[:s] == 5
    end

    test "same-table batch falls back to default_value when the query fails" do
      records = [struct(UserResource, id: "id-1", age: 30)]
      agg = %{kind: :sum, name: :s, field: :age, relationship_path: [], resource: UserResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], UserResource, ErrRepo, [])
      assert record.aggregates[:s] == 0
    end

    test "belongs_to batch falls back to default_value when the query fails" do
      records = [struct(MemberResource, id: "m1", team_id: "t1")]
      agg = %{kind: :count, name: :c, field: nil, relationship_path: [:team], resource: MemberResource, default_value: 0}

      [record] = Aggregate.attach(records, [agg], MemberResource, ErrRepo, [])
      assert record.aggregates[:c] == 0
    end
  end
end
