defmodule AshClickhouse.RepoTest do
  @moduledoc "Unit tests for AshClickhouse.Repo generated functions."
  use ExUnit.Case, async: true

  describe "__ash_clickhouse_repo__/0 contract" do
    test "TestRepo exports the marker function so mix tasks can discover it" do
      assert function_exported?(AshClickhouse.TestRepo, :__ash_clickhouse_repo__, 0)
      assert AshClickhouse.TestRepo.__ash_clickhouse_repo__() == true
    end
  end

  describe "generated repo functions" do
    test "insert_rows/4 and ping/0 are exported" do
      assert function_exported?(AshClickhouse.TestRepo, :insert_rows, 4)
      assert function_exported?(AshClickhouse.TestRepo, :ping, 0)
      assert function_exported?(AshClickhouse.TestRepo, :query, 3)
      assert function_exported?(AshClickhouse.TestRepo, :query!, 3)
      assert function_exported?(AshClickhouse.TestRepo, :create_database, 1)
      assert function_exported?(AshClickhouse.TestRepo, :drop_database, 1)
    end
  end

  describe "config_to_conn_opts/1" do
    test "reads :pool_size when configured" do
      defmodule RepoWithPoolSize do
        use AshClickhouse.Repo, otp_app: :ash_clickhouse

        def config, do: [url: "http://localhost:8123", database: "db", pool_size: 25]
      end

      opts = AshClickhouse.Repo.config_to_conn_opts(RepoWithPoolSize)
      assert Keyword.get(opts, :pool_size) == 25
      assert Keyword.get(opts, :url) == "http://localhost:8123"
    end

    test "defaults :pool_size to 10" do
      defmodule RepoWithDefaults do
        use AshClickhouse.Repo, otp_app: :ash_clickhouse

        def config, do: []
      end

      opts = AshClickhouse.Repo.config_to_conn_opts(RepoWithDefaults)
      assert Keyword.get(opts, :pool_size) == 10
    end
  end
end
