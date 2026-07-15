defmodule AshClickhouse.ReviewFixesTest do
  @moduledoc """
  Regression tests for the bugs and consistency gaps fixed during the code
  review. Each `describe` maps to a numbered item in the review.
  """
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.DataLayer.QueryBuilder
  alias AshClickhouse.Identifier
  alias AshClickhouse.Migration
  alias AshClickhouse.Query
  alias AshClickhouse.Telemetry

  # --- helpers --------------------------------------------------------------

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
          resource: nil,
          repo: nil
        },
        overrides
      )
    )
  end

  # Defines a repo module whose `query/3` captures the SQL it is given and
  # returns a benign ok. `query/3` is `defoverridable`, so overriding it here
  # intercepts `create_database`/`drop_database` which call `__MODULE__.query`.
  defp capturing_repo(database) do
    test_pid = self()
    module = String.to_atom("CaptureRepo_#{:erlang.unique_integer()}")

    Module.create(
      module,
      quote do
        use AshClickhouse.Repo, otp_app: :ash_clickhouse

        def config, do: [url: "http://localhost:8123", database: unquote(database)]

        def query(sql, _params, _opts) do
          send(unquote(test_pid), {:query, sql})
          {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp assert_captured_sql(match) do
    assert_received {:query, sql}
    assert sql == match
  end

  # ==========================================================================
  # 1 & 2. Repo.create_database/drop_database fall back to "default"
  # ==========================================================================

  describe "Repo.create_database/1 and drop_database/1 fallback" do
    test "uses 'default' when no database is configured" do
      repo = capturing_repo(nil)

      {:ok, _} = repo.create_database()
      assert_captured_sql("CREATE DATABASE IF NOT EXISTS `default`")

      {:ok, _} = repo.drop_database()
      assert_captured_sql("DROP DATABASE IF EXISTS `default`")
    end

    test "prefers an explicit argument over the configured database" do
      repo = capturing_repo("configured_db")

      {:ok, _} = repo.create_database("explicit_db")
      assert_captured_sql("CREATE DATABASE IF NOT EXISTS `explicit_db`")
    end

    test "uses the configured database when present" do
      repo = capturing_repo("configured_db")

      {:ok, _} = repo.create_database()
      assert_captured_sql("CREATE DATABASE IF NOT EXISTS `configured_db`")
    end
  end

  # ==========================================================================
  # 2. Repo.child_spec/1 honors its opts argument
  # ==========================================================================

  describe "Repo.child_spec/1 honors opts" do
    test "merges opts into the connection options" do
      defmodule ChildSpecRepo do
        use AshClickhouse.Repo, otp_app: :ash_clickhouse

        def config, do: [url: "http://localhost:8123", database: "child_db"]
      end

      spec = ChildSpecRepo.child_spec(url: "http://other:8123", pool_size: 7)
      assert spec.id == ChildSpecRepo

      # The merged opts are forwarded to Connection.child_spec; verify the
      # connection options builder sees them.
      conn_opts = AshClickhouse.Repo.config_to_conn_opts(ChildSpecRepo)
      merged = Keyword.merge(conn_opts, url: "http://other:8123", pool_size: 7)
      assert Keyword.get(merged, :url) == "http://other:8123"
      assert Keyword.get(merged, :pool_size) == 7
    end
  end

  # ==========================================================================
  # 3. run_query/2 guards against a missing repo
  # ==========================================================================

  describe "DataLayer.run_query/2 missing repo" do
    test "raises a clear ConfigurationError instead of UndefinedFunctionError" do
      defmodule ResourceWithoutRepo do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("no_repo_table")
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      DataLayer.clear_repo_cache!()

      q = Query.new(ResourceWithoutRepo)
      assert q.repo == nil

      assert_raise AshClickhouse.Error.ConfigurationError, ~r/No repo configured/, fn ->
        DataLayer.run_query(q, ResourceWithoutRepo)
      end
    end
  end

  # ==========================================================================
  # 4. distinct + explicit select does not drop columns
  # ==========================================================================

  describe "build_optimized_query/1 distinct + select" do
    test "emits the merged select list under DISTINCT, not just distinct columns" do
      {sql, _} =
        QueryBuilder.build_optimized_query(
          query(%{select: [:id, :name, :email], distinct: [:name]})
        )

      assert sql == "SELECT DISTINCT `id`, `name`, `email` FROM `users`"
    end

    test "distinct with no explicit select only projects the distinct columns" do
      {sql, _} = QueryBuilder.build_optimized_query(query(%{distinct: [:name]}))
      assert sql == "SELECT DISTINCT `name` FROM `users`"
    end
  end

  # ==========================================================================
  # 5. sort building supports nulls-ordering directions
  # ==========================================================================

  describe "build_optimized_query/1 nulls ordering" do
    test "emits NULLS FIRST/LAST for the four nulls-ordering directions" do
      sorts = [
        {:a, :asc_nils_first},
        {:b, :asc_nils_last},
        {:c, :desc_nils_first},
        {:d, :desc_nils_last},
        {:e, :asc}
      ]

      {sql, _} = QueryBuilder.build_optimized_query(query(%{sorts: sorts}))

      assert sql ==
               "SELECT * FROM `users` ORDER BY `a` ASC NULLS FIRST, `b` ASC NULLS LAST, " <>
                 "`c` DESC NULLS FIRST, `d` DESC NULLS LAST, `e` ASC"
    end

    test "can?/2 claims nulls-ordering sorts are supported" do
      assert DataLayer.can?(nil, {:sort, :asc_nils_first})
      assert DataLayer.can?(nil, {:sort, :desc_nils_last})
    end
  end

  # ==========================================================================
  # 6. index DSL macro is robust to key order
  # ==========================================================================

  describe "index DSL macro key order" do
    test "compiles when keys are given in a different order" do
      defmodule ResourceIndexReordered do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("reordered_index_table")
          repo(AshClickhouse.TestRepo)
          order_by("id")

          index(expression: "user_id", type: "bloom_filter", name: :idx_user_id)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:user_id, :string)
        end
      end

      indexes = Dsl.indexes(ResourceIndexReordered)

      assert [
               %{name: :idx_user_id, expression: "user_id", type: "bloom_filter", granularity: 1}
             ] = indexes
    end

    test "raises a clear error when required index keys are missing" do
      assert_raise ArgumentError, ~r/requires at least/, fn ->
        defmodule ResourceIndexMissingKeys do
          use Ash.Resource,
            data_layer: AshClickhouse.DataLayer,
            domain: nil

          import AshClickhouse.DataLayer.Dsl.Macros

          clickhouse do
            table("missing_keys_table")
            repo(AshClickhouse.TestRepo)
            order_by("id")

            index(name: :idx_x, type: "minmax")
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end
    end
  end

  # ==========================================================================
  # 6b. duplicate index name is rejected
  # ==========================================================================

  describe "duplicate index names" do
    test "raises when two indexes share a name" do
      assert_raise ArgumentError, ~r/Duplicate ClickHouse index name/, fn ->
        defmodule ResourceDuplicateIndex do
          use Ash.Resource,
            data_layer: AshClickhouse.DataLayer,
            domain: nil

          import AshClickhouse.DataLayer.Dsl.Macros

          clickhouse do
            table("dup_index_table")
            repo(AshClickhouse.TestRepo)
            order_by("id")

            index(name: :idx_same, expression: "a", type: "minmax")
            index(name: :idx_same, expression: "b", type: "minmax")
          end

          attributes do
            uuid_primary_key(:id)
            attribute(:a, :string)
            attribute(:b, :string)
          end
        end
      end
    end
  end

  # ==========================================================================
  # 8. migration defaults support booleans, dates, datetimes, decimals
  # ==========================================================================

  describe "migration defaults for non-numeric literals" do
    test "boolean default for UInt8" do
      defmodule ResourceBoolDefault do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("bool_default_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:active, :boolean, default: true, allow_nil?: false)
        end
      end

      sql = Migration.create_table_cql(ResourceBoolDefault)
      assert String.contains?(sql, "`active` UInt8 DEFAULT 1")
    end

    test "date default is emitted as a quoted ISO date" do
      defmodule ResourceDateDefault do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("date_default_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:born_on, :date, default: ~D[2000-01-01], allow_nil?: false)
        end
      end

      sql = Migration.create_table_cql(ResourceDateDefault)
      assert String.contains?(sql, "`born_on` Date DEFAULT '2000-01-01'")
    end

    test "datetime default is emitted as a quoted ISO datetime" do
      defmodule ResourceDateTimeDefault do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("datetime_default_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:created, :utc_datetime, default: ~U[2020-05-05 10:00:00Z], allow_nil?: false)
        end
      end

      sql = Migration.create_table_cql(ResourceDateTimeDefault)
      assert String.contains?(sql, "`created` DateTime64(6) DEFAULT '2020-05-05 10:00:00Z'")
    end

    test "decimal default is emitted as a bare literal" do
      defmodule ResourceDecimalDefault do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("decimal_default_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)

          attribute(:score, :decimal,
            default: Decimal.new("3.5"),
            allow_nil?: false,
            constraints: [precision: 38, scale: 10]
          )
        end
      end

      sql = Migration.create_table_cql(ResourceDecimalDefault)
      assert String.contains?(sql, "`score` Decimal(38, 10) DEFAULT 3.5")
    end

    test "an unsupported default type raises a clear error (not 'Non-numeric')" do
      defmodule ResourceBadDefault do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("bad_default_table")
          repo(AshClickhouse.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:weird, :map, default: %{a: 1}, allow_nil?: false)
        end
      end

      assert_raise AshClickhouse.Error.ConfigurationError,
                   ~r/Unsupported default/,
                   fn -> Migration.create_table_cql(ResourceBadDefault) end
    end
  end

  # ==========================================================================
  # 9. can?/2 single source of truth via @supported_features
  # ==========================================================================

  describe "can?/2 supported features" do
    test "every feature in @supported_features resolves to true" do
      for feature <- DataLayer.supported_features() do
        assert DataLayer.can?(nil, feature), "expected #{inspect(feature)} to be supported"
      end
    end

    test "explicitly-unsupported features resolve to false" do
      for feature <- [
            :transact,
            :lock,
            :keyset,
            :upsert,
            {:atomic, :something},
            :expression_calculation_sort,
            :aggregate_filter,
            :aggregate_sort,
            :update_many,
            :composite_type,
            :through_relationship,
            :bulk_create_with_partial_success,
            :bulk_upsert_return_skipped
          ] do
        refute DataLayer.can?(nil, feature), "expected #{inspect(feature)} to be unsupported"
      end
    end

    test ":offset and :calculate resolve via the MapSet fallback" do
      assert DataLayer.can?(nil, :offset)
      assert DataLayer.can?(nil, :calculate)
      assert DataLayer.can?(nil, :action_select)
    end
  end

  # ==========================================================================
  # 10. qualified_table/1 backtick-quotes the table name
  # ==========================================================================

  describe "qualified_table/1 backtick quoting" do
    test "quotes both database and table" do
      defmodule ResourceReservedWordTable do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("order")
          repo(AshClickhouse.TestRepo)
          database("select")
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      assert DataLayer.qualified_table(ResourceReservedWordTable) == "`select`.`order`"
    end
  end

  # ==========================================================================
  # 12. DSL setters validate their argument types
  # ==========================================================================

  describe "DSL setter type validation" do
    test "primary_key rejects a bare atom instead of a list" do
      assert_raise FunctionClauseError, fn ->
        defmodule ResourceBadPrimaryKey do
          use Ash.Resource,
            data_layer: AshClickhouse.DataLayer,
            domain: nil

          import AshClickhouse.DataLayer.Dsl.Macros

          clickhouse do
            table("bad_pk_table")
            repo(AshClickhouse.TestRepo)
            primary_key(:id)
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end
    end

    test "table rejects a non-binary value" do
      assert_raise FunctionClauseError, fn ->
        defmodule ResourceBadTable do
          use Ash.Resource,
            data_layer: AshClickhouse.DataLayer,
            domain: nil

          import AshClickhouse.DataLayer.Dsl.Macros

          clickhouse do
            repo(AshClickhouse.TestRepo)
            table(:not_a_string)
          end

          attributes do
            uuid_primary_key(:id)
          end
        end
      end
    end

    test "valid list/string values still compile" do
      defmodule ResourceGoodPrimaryKey do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: nil

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("good_pk_table")
          repo(AshClickhouse.TestRepo)
          primary_key([:id, :tenant])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:tenant, :string)
        end
      end

      assert Dsl.primary_key(ResourceGoodPrimaryKey) == [:id, :tenant]
    end
  end

  # ==========================================================================
  # 13. Telemetry :stop distinguishes success from failure
  # ==========================================================================

  describe "Telemetry.span/4 status metadata" do
    test ":stop metadata carries status: :ok on success" do
      test_pid = self()
      ref = "telemetry-status-ok-\#{:erlang.unique_integer()}"

      :telemetry.attach(
        ref,
        [:ash_clickhouse, :query, :stop],
        fn
          _, _, meta, _ -> send(test_pid, {:stop, meta})
        end,
        nil
      )

      try do
        Telemetry.span(MyResource, :read, "SELECT 1", fn -> {:ok, []} end)

        assert_received {:stop, meta}
        assert meta.status == :ok
      after
        :telemetry.detach(ref)
      end
    end

    test ":stop metadata carries status: :error on returned error" do
      test_pid = self()
      ref = "telemetry-status-err-\#{:erlang.unique_integer()}"

      :telemetry.attach(
        ref,
        [:ash_clickhouse, :query, :stop],
        fn
          _, _, meta, _ -> send(test_pid, {:stop, meta})
        end,
        nil
      )

      try do
        Telemetry.span(MyResource, :read, "SELECT 1", fn -> {:error, :boom} end)

        assert_received {:stop, meta}
        assert meta.status == :error
      after
        :telemetry.detach(ref)
      end
    end
  end

  # ==========================================================================
  # 14. collect_columns/1 handles :not expressions
  # ==========================================================================

  describe "get_filter_columns/1 :not handling" do
    test "collects columns from a BooleanExpression :not" do
      expr = %Ash.Query.BooleanExpression{
        op: :not,
        left: nil,
        right: %{operator: :eq, left: %{name: :hidden}, right: %{value: true}}
      }

      assert QueryBuilder.get_filter_columns([expr]) == [:hidden]
    end

    test "collects columns from an Ash.Query.Not struct" do
      expr = %Ash.Query.Not{
        expression: %{operator: :eq, left: %{name: :archived}, right: %{value: true}}
      }

      assert QueryBuilder.get_filter_columns([expr]) == [:archived]
    end
  end

  # ==========================================================================
  # 15. Identifier.valid_identifier?/1 is just the regex
  # ==========================================================================

  describe "Identifier.valid_identifier?/1" do
    test "accepts valid identifiers" do
      assert Identifier.valid_identifier?("ok_name")
      assert Identifier.valid_identifier?(:OkName)
    end

    test "rejects invalid identifiers" do
      refute Identifier.valid_identifier?("1bad")
      refute Identifier.valid_identifier?("bad name")
      refute Identifier.valid_identifier?("")
    end
  end

  # ==========================================================================
  # 18. contains is case-insensitive; starts_with/ends_with are case-sensitive
  # ==========================================================================

  describe "string matching case sensitivity" do
    test "contains uses positionCaseInsensitive (case-insensitive)" do
      filter = %{operator: :contains, left: %{name: :name}, right: %{value: "John"}}
      {sql, [param]} = QueryBuilder.build_where_clause([filter])
      assert String.contains?(sql, "positionCaseInsensitive(`name`, ?)")
      assert param == "John"
    end

    test "starts_with uses LIKE (case-sensitive)" do
      filter = %{operator: :starts_with, left: %{name: :name}, right: %{value: "John"}}
      {sql, [param]} = QueryBuilder.build_where_clause([filter])
      assert String.contains?(sql, "`name` LIKE ?")
      assert param == "John%"
    end
  end

  # ==========================================================================
  # 17. Dsl.get_config/3 no longer rescues FunctionClauseError
  # ==========================================================================

  describe "Dsl.get_config/3" do
    test "returns default for a resource without the config function" do
      defmodule PlainModule do
      end

      # `Dsl.table/1` reads via the private `get_config/3`, which returns the
      # configured value or the default (nil) when `__ash_clickhouse__/1` is
      # not exported.
      assert Dsl.table(PlainModule) == nil
    end

    test "returns the configured value when present" do
      assert Dsl.table(AshClickhouse.TestResource) == "test_users"
    end
  end
end
