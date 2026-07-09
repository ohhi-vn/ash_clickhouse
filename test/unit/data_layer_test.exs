defmodule AshClickhouse.DataLayerTest do
  @moduledoc "Unit tests for AshClickhouse.DataLayer feature support and helpers."
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer

  describe "feature support (can?/2)" do
    test "supports core CRUD and query features" do
      assert DataLayer.can?(nil, :create)
      assert DataLayer.can?(nil, :read)
      assert DataLayer.can?(nil, :update)
      assert DataLayer.can?(nil, :destroy)
      assert DataLayer.can?(nil, :filter)
      assert DataLayer.can?(nil, :offset)
      assert DataLayer.can?(nil, :limit)
      assert DataLayer.can?(nil, :sort)
      assert DataLayer.can?(nil, :distinct)
      assert DataLayer.can?(nil, :bulk_create)
    end

    test "supports streaming reads" do
      assert DataLayer.can?(nil, :stream)
    end

    test "does not support unsupported features" do
      refute DataLayer.can?(nil, :transact)
      refute DataLayer.can?(nil, :lock)
      refute DataLayer.can?(nil, :keyset)
      refute DataLayer.can?(nil, :upsert)
      refute DataLayer.can?(nil, :join)
      refute DataLayer.can?(nil, :combine)
    end
  end

  describe "qualified_table/1" do
    test "builds a qualified table name for a resource" do
      assert DataLayer.qualified_table(AshClickhouse.TestResource) ==
               "`ash_clickhouse_test`.test_users"
    end
  end

  describe "source/1" do
    test "resolves the table name from the DSL" do
      assert DataLayer.source(AshClickhouse.TestResource) == "test_users"
    end
  end
end
