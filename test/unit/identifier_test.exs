defmodule AshClickhouse.IdentifierTest do
  @moduledoc "Unit tests for AshClickhouse.Identifier."
  use ExUnit.Case, async: true

  alias AshClickhouse.Identifier

  describe "quote_name/1" do
    test "quotes a simple identifier" do
      assert Identifier.quote_name("users") == "`users`"
    end

    test "escapes embedded backticks" do
      assert Identifier.quote_name("my`table") == "`my``table`"
    end

    test "accepts atoms" do
      assert Identifier.quote_name(:users) == "`users`"
    end
  end

  describe "sanitize!/1" do
    test "accepts valid identifiers" do
      assert Identifier.sanitize!("valid_name") == "valid_name"
      assert Identifier.sanitize!("_private") == "_private"
      assert Identifier.sanitize!("Table123") == "Table123"
    end

    test "rejects identifiers starting with a digit" do
      assert_raise ArgumentError, fn -> Identifier.sanitize!("1invalid") end
    end

    test "rejects identifiers with dashes" do
      assert_raise ArgumentError, fn -> Identifier.sanitize!("invalid-name") end
    end

    test "rejects identifiers with spaces" do
      assert_raise ArgumentError, fn -> Identifier.sanitize!("invalid name") end
    end
  end

  describe "valid_identifier?/1" do
    test "returns boolean without raising" do
      assert Identifier.valid_identifier?("ok_name")
      refute Identifier.valid_identifier?("1bad")
      refute Identifier.valid_identifier?("bad name")
    end
  end

  describe "validate_database!/1" do
    test "accepts nil and valid names" do
      assert Identifier.validate_database!(nil) == :ok
      assert Identifier.validate_database!("my_db") == :ok
    end

    test "rejects invalid database names" do
      assert_raise ArgumentError, fn -> Identifier.validate_database!("bad-db") end
    end
  end

  describe "validate_table!/1" do
    test "accepts valid table names" do
      assert Identifier.validate_table!("my_table") == :ok
    end

    test "rejects invalid table names" do
      assert_raise ArgumentError, fn -> Identifier.validate_table!("1table") end
    end
  end
end
