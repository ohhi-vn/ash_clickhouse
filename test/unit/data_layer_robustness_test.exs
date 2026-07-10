defmodule AshClickhouse.DataLayerRobustnessTest do
  @moduledoc """
  Tests for robustness fixes that don't require a live ClickHouse connection:

  - item #6: `source/1` no longer relies on the process dictionary
  - item #7: `Connection.stop/1` actually tears down the client
  - item #8: the repo ETS cache exists (created once at app start)
  - item #9: `escape_default` rejects non-numeric defaults on numeric columns
  """
  use ExUnit.Case, async: false

  alias AshClickhouse.Connection
  alias AshClickhouse.DataLayer

  describe "source/1 (item #6)" do
    test "resolves the table name without process-dictionary caching" do
      # Should be deterministic and not depend on per-process state.
      assert DataLayer.source(AshClickhouse.TestResource) == "test_users"
      assert DataLayer.source(AshClickhouse.TestResource) == "test_users"
    end
  end

  describe "repo ETS cache (item #8)" do
    test "the cache table is created once at application start" do
      assert :ets.whereis(:ash_clickhouse_repo_cache) != :undefined
    end
  end

  describe "Connection.stop/1 (item #7)" do
    test "stopping a started connection removes the cached struct" do
      name = :test_stop_conn

      {:ok, _pid} =
        Connection.start_link(
          name: name,
          url: "http://localhost:8123",
          database: "ash_clickhouse_test"
        )

      assert Connection.get_conn(name) != nil

      assert Connection.stop(name) == :ok
      # The cached connection struct is gone after a real stop.
      assert Connection.get_conn(name) == nil
    end

    test "stopping an unknown connection is a no-op" do
      assert Connection.stop(:never_started_conn_1234) == :ok
    end
  end

  describe "escape_default numeric validation (item #9)" do
    defmodule NumericDefaultResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: AshClickhouse.TestDomain

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("numeric_default")
        repo(AshClickhouse.TestRepo)
        database("ash_clickhouse_test")
        engine("MergeTree()")
        order_by("id")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:age, :integer, default: 42)
      end
    end

    defmodule StringDefaultResource do
      use Ash.Resource,
        data_layer: AshClickhouse.DataLayer,
        domain: AshClickhouse.TestDomain

      import AshClickhouse.DataLayer.Dsl.Macros

      clickhouse do
        table("string_default")
        repo(AshClickhouse.TestRepo)
        database("ash_clickhouse_test")
        engine("MergeTree()")
        order_by("id")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string, default: "O'Brien")
      end
    end

    # NOTE: Ash validates attribute defaults at compile time, so a non-numeric
    # default on a numeric column is rejected by Ash before it ever reaches the
    # migration. `inspect_numeric_default/2` therefore remains defensive
    # hardening (it raises `ConfigurationError` for any non-numeric literal that
    # somehow gets through), but it is not reachable via a normal resource.

    test "numeric default on a numeric column is emitted bare" do
      sql = AshClickhouse.Migration.create_table_cql(NumericDefaultResource)
      assert sql =~ "DEFAULT 42"
      # Must be a bare number, not a quoted string literal.
      refute sql =~ "DEFAULT '42'"
    end

    test "string default is still quoted and escaped" do
      sql = AshClickhouse.Migration.create_table_cql(StringDefaultResource)
      assert sql =~ "DEFAULT 'O\\'Brien'"
    end
  end
end
