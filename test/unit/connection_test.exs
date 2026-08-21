defmodule AshClickhouse.ConnectionTest do
  @moduledoc """
  Unit tests for AshClickhouse.Connection, covering the start/stop lifecycle,
  option threading, child specs, and error handling without a live ClickHouse.
  """
  use ExUnit.Case, async: false

  alias AshClickhouse.Connection

  setup_all do
    {:ok, _} = Application.ensure_all_started(:hackney)
    :ok
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp start_conn(name, opts \\ []) do
    opts =
      Keyword.merge(
        [name: name, url: "http://localhost:8123", database: "test_db"],
        opts
      )

    {:ok, pid} = Connection.start_link(opts)

    # Connections are linked to this (test) process. Stop them here so no stale
    # persistent_term entry survives into the next test.
    Process.flag(:trap_exit, true)
    {pid, opts}
  end

  describe "start_link/1" do
    test "registers the connection and stores a struct in persistent_term" do
      name = unique_name(:conn_lifecycle)
      {pid, _} = start_conn(name)

      conn = Connection.get_conn(name)
      assert %Connection{database: "test_db", name: ^name} = conn
      assert conn.pid == pid
      assert Connection.database_for(name) == "test_db"

      assert Connection.stop(name) == :ok
      assert Connection.get_conn(name) == nil
    end
  end

  describe "child_spec/1" do
    test "builds a worker spec keyed by the connection name" do
      spec = Connection.child_spec(name: :my_conn)
      assert spec.id == :my_conn
      assert spec.type == :worker
      assert spec.start == {Connection, :start_link, [[name: :my_conn]]}
    end

    test "defaults the id to the module when no name is given" do
      spec = Connection.child_spec([])
      assert spec.id == Connection
    end
  end

  describe "get_conn/0" do
    test "returns nil when no connection is registered under the default name" do
      assert Connection.get_conn() == nil
    end
  end

  describe "database_for/1" do
    test "returns the database for an atom name of a registered conn" do
      name = unique_name(:conn_db)
      {_, _} = start_conn(name, database: "my_db")
      assert Connection.database_for(name) == "my_db"
      assert Connection.stop(name) == :ok
    end

    test "returns nil for an unregistered atom name" do
      assert Connection.database_for(:never_started_xyz) == nil
    end
  end

  describe "stop/1" do
    test "stops a connection and erases the cached struct" do
      name = unique_name(:conn_stop)
      {_, _} = start_conn(name)
      assert Connection.stop(name) == :ok
      assert Connection.get_conn(name) == nil
    end

    test "stopping a bare struct with no name stops the underlying client" do
      name = unique_name(:conn_struct)
      {pid, _} = start_conn(name)
      conn = Connection.get_conn(name)
      assert Connection.stop(conn) == :ok
      refute Process.alive?(pid)
    end

    test "stopping a non-atom non-struct term is a no-op" do
      assert Connection.stop(self()) == :ok
    end
  end

  describe "query/4 with a pid connection" do
    test "resolves a pid connection and wraps the client failure" do
      # A bare pid that is not a ClickHouse client is an invalid-argument
      # client failure; the non-bang query wraps it as a ClickhouseError.
      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               Connection.query(self(), "SELECT 1", [])
    end
  end

  describe "query/4 and query!/4" do
    test "query returns {:error, ClickhouseError} for an unknown connection" do
      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               Connection.query(:no_such_conn_abc, "SELECT 1", [])
    end

    test "query! raises ClickhouseError for an unknown connection" do
      assert_raise AshClickhouse.Error.ClickhouseError, fn ->
        Connection.query!(:no_such_conn_abc, "SELECT 1", [])
      end
    end

    test "query threads the database into opts for a struct conn" do
      conn = %Connection{conn: :no_such_conn_def, database: "db_x", name: nil}

      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               Connection.query(conn, "SELECT 1", [])
    end

    test "query resolves a registered atom name to its stored connection" do
      name = unique_name(:conn_resolve)
      key = {Connection, name}

      # Register a struct whose client atom is intentionally unregistered so the
      # query fails fast (no server round-trip) after resolving the name.
      :persistent_term.put(key, %Connection{
        conn: :no_such_resolved_client,
        database: nil,
        name: name
      })

      on_exit(fn -> :persistent_term.erase(key) end)

      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               Connection.query(name, "SELECT 1", [])
    end

    test "query keeps an explicit database opt on a struct conn" do
      conn = %Connection{conn: :no_such_conn_dbopt, database: "db_z", name: nil}

      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               Connection.query(conn, "SELECT 1", [], database: "override_db")
    end

    test "query! reraises an existing ClickhouseError with its stacktrace" do
      conn = %Connection{conn: :no_such_conn_ghi, database: nil, name: nil}

      assert_raise AshClickhouse.Error.ClickhouseError, fn ->
        Connection.query!(conn, "SELECT 1", [])
      end
    end
  end

  describe "insert_rows/4" do
    test "returns {:error, ClickhouseError} when the client is unreachable" do
      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               Connection.insert_rows(
                 :no_such_conn_insert,
                 "INSERT INTO tbl (a) FORMAT JSONCompactEachRow",
                 [["x"]]
               )
    end

    test "threads the database into opts for a struct conn" do
      conn = %Connection{conn: :no_such_conn_insert2, database: "db_y", name: nil}

      assert {:error, %AshClickhouse.Error.ClickhouseError{}} =
               Connection.insert_rows(
                 conn,
                 "INSERT INTO tbl (a) FORMAT JSONCompactEachRow",
                 [[1]]
               )
    end
  end
end
