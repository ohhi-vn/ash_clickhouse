defmodule AshClickhouse.ErrorTest do
  @moduledoc "Unit tests for AshClickhouse.Error structs and helpers."
  use ExUnit.Case, async: true

  alias AshClickhouse.Error

  describe "ClickhouseError" do
    test "from_error/1 wraps a binary message" do
      err = Error.ClickhouseError.from_error("boom")
      assert %Error.ClickhouseError{message: "boom"} = err
    end

    test "from_error/1 passes through an existing ClickhouseError" do
      original = %Error.ClickhouseError{message: "x", reason: :y}
      assert Error.ClickhouseError.from_error(original) == original
    end

    test "from_error/1 wraps a struct with a message field" do
      err = Error.ClickhouseError.from_error(%{message: "nested"})
      assert %Error.ClickhouseError{message: "nested"} = err
    end

    test "exception/1 builds from a binary or keyword list" do
      assert %Error.ClickhouseError{message: "m"} = Error.ClickhouseError.exception("m")

      assert %Error.ClickhouseError{message: "m", query: "q"} =
               Error.ClickhouseError.exception(query: "q", message: "m")
    end
  end

  describe "QueryError" do
    test "from_error/1 handles binaries, structs and other terms" do
      assert %Error.QueryError{message: "q"} = Error.QueryError.from_error("q")
      assert %Error.QueryError{} = Error.QueryError.from_error(:whatever)
      existing = %Error.QueryError{message: "e"}
      assert Error.QueryError.from_error(existing) == existing
    end
  end

  describe "ConfigurationError" do
    test "raises with a message" do
      assert_raise Error.ConfigurationError, fn ->
        raise Error.ConfigurationError, "bad config"
      end
    end

    test "exception/1 builds from binary or keyword list" do
      assert %Error.ConfigurationError{message: "c"} = Error.ConfigurationError.exception("c")

      assert %Error.ConfigurationError{message: "c"} =
               Error.ConfigurationError.exception(message: "c")
    end
  end

  describe "wrap_clickhouse_error/1" do
    test "always returns a ClickhouseError" do
      assert %Error.ClickhouseError{} = Error.wrap_clickhouse_error("anything")
      assert %Error.ClickhouseError{} = Error.wrap_clickhouse_error(%{message: "x"})
    end
  end
end
