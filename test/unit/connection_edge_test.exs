defmodule AshClickhouse.ConnectionEdgeTest do
  @moduledoc """
  Edge-case unit tests for AshClickhouse.Connection.

  These exercise the connection wrapper's option threading, database resolution,
  and error handling without requiring a live ClickHouse server.
  """
  use ExUnit.Case, async: false

  alias AshClickhouse.Connection

  describe "with_default_format/1" do
    test "adds the default format when missing" do
      opts = Connection.with_default_format([])
      assert Keyword.get(opts, :default_format) == "JSONCompactEachRow"
    end

    test "does not override an explicit format" do
      opts = Connection.with_default_format(default_format: "JSONEachRow")
      assert Keyword.get(opts, :default_format) == "JSONEachRow"
    end
  end

  describe "database_for/1" do
    test "reads the database from a connection struct" do
      conn = %Connection{database: "my_db"}
      assert Connection.database_for(conn) == "my_db"
    end

    test "returns nil for an unknown atom name" do
      assert Connection.database_for(:never_started_conn_xyz) == nil
    end

    test "returns nil for non-conn terms" do
      assert Connection.database_for(self()) == nil
      assert Connection.database_for(42) == nil
    end
  end

  describe "query/4 and query!/4 error handling" do
    test "a raised client error is caught and returned as {:error, _}" do
      # Point at a name that has no real client; `ClickHouse.query` will raise
      # because the connection is not a valid pid/name. The rescue clause must
      # convert it to an error tuple rather than letting it propagate.
      assert {:error, _} = Connection.query(:no_such_connection_abc, "SELECT 1", [])
    end
  end

  describe "stop/1" do
    test "stopping an unknown connection is a no-op" do
      assert Connection.stop(:never_started_conn_1234) == :ok
    end

    test "stopping a bare struct with no name is a no-op" do
      assert Connection.stop(%Connection{}) == :ok
    end

    test "stopping a non-conn term is a no-op" do
      assert Connection.stop(:not_a_connection) == :ok
    end
  end

  describe "get_conn/1" do
    test "returns nil for an unknown connection name" do
      assert Connection.get_conn(:unknown_conn_name_999) == nil
    end
  end
end
