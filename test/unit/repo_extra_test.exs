defmodule AshClickhouse.RepoExtraTest do
  @moduledoc "Additional unit tests for AshClickhouse.Repo generated functions."
  use ExUnit.Case, async: true

  describe "capturing repo (overrides query/3)" do
    defmodule CapturingRepo do
      use AshClickhouse.Repo, otp_app: :ash_clickhouse

      def config, do: [url: "http://localhost:8123", database: "captured_db"]

      def query(sql, _params, _opts) do
        send(self(), {:query, sql})
        {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}
      end

      def query!(sql, _params, _opts) do
        send(self(), {:query, sql})
        %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}
      end
    end

    test "database/0 reads the configured database" do
      assert CapturingRepo.database() == "captured_db"
    end

    test "create_database/1 generates a CREATE DATABASE statement" do
      assert {:ok, _} = CapturingRepo.create_database("my_new_db")
      assert_received {:query, sql}
      assert sql == "CREATE DATABASE IF NOT EXISTS `my_new_db`"
    end

    test "drop_database/1 generates a DROP DATABASE statement" do
      assert {:ok, _} = CapturingRepo.drop_database("my_new_db")
      assert_received {:query, sql}
      assert sql == "DROP DATABASE IF EXISTS `my_new_db`"
    end

    test "create_database/1 rejects invalid database names" do
      assert_raise ArgumentError, fn -> CapturingRepo.create_database("bad-db") end
    end

    test "query!/3 executes and returns the result" do
      result = CapturingRepo.query!("SELECT 1", [])
      assert %ClickHouse.Result{} = result
      assert_received {:query, "SELECT 1"}
    end

    test "ping/0 returns true on a successful query" do
      assert CapturingRepo.ping() == true
      assert_received {:query, "SELECT 1"}
    end

    test "connection/0 returns nil when no connection is started" do
      assert CapturingRepo.connection() == nil
    end
  end

  describe "config_to_conn_opts/1 defaults" do
    defmodule DefaultRepo do
      use AshClickhouse.Repo, otp_app: :ash_clickhouse

      def config, do: []
    end

    test "defaults url, pool_size, pool_timeout and ping_retry" do
      opts = AshClickhouse.Repo.config_to_conn_opts(DefaultRepo)
      assert Keyword.get(opts, :url) == "http://localhost:8123"
      assert Keyword.get(opts, :pool_size) == 10
      assert Keyword.get(opts, :pool_timeout) == 30_000
      assert Keyword.get(opts, :ping_retry) == 30_000
    end
  end
end
