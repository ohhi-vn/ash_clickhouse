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

    test "from_error/1 inspects an arbitrary term as the message" do
      err = Error.ClickhouseError.from_error({:custom, :reason})

      assert %Error.ClickhouseError{message: "{:custom, :reason}", reason: {:custom, :reason}} =
               err
    end

    test "exception/1 builds from a binary or keyword list" do
      assert %Error.ClickhouseError{message: "m"} = Error.ClickhouseError.exception("m")

      assert %Error.ClickhouseError{message: "m", query: "q"} =
               Error.ClickhouseError.exception(query: "q", message: "m")
    end

    test "exception/1 falls back to from_error/1 for non-list non-binary terms" do
      err = Error.ClickhouseError.exception({:error, :boom})
      assert %Error.ClickhouseError{message: "{:error, :boom}", reason: {:error, :boom}} = err
    end

    test "a ClickhouseError can be raised with a message and carries fields" do
      assert_raise Error.ClickhouseError, "boom", fn ->
        raise Error.ClickhouseError, "boom"
      end
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

  describe "client_error?/1" do
    test "recognises the clickhouse client error structs" do
      assert Error.client_error?(%ClickHouse.QueryError{message: "bad query"})
      assert Error.client_error?(%ClickHouse.ConnectionError{})
      assert Error.client_error?(%ClickHouse.DatabaseError{})
      assert Error.client_error?(%ClickHouse.ParsingError{})
      assert Error.client_error?(%ClickHouse.StreamError{})
      assert Error.client_error?(%ClickHouse.SystemError{})
      assert Error.client_error?(%ClickHouse.CoordinationError{})
    end

    test "rejects other terms" do
      refute Error.client_error?(%RuntimeError{message: "nope"})
      refute Error.client_error?(:not_an_error)
      refute Error.client_error?(nil)
    end
  end

  describe "reraise_or_wrap/2" do
    test "converts a client error into a ClickhouseError" do
      e = %ClickHouse.QueryError{message: "syntax"}
      assert_raise Error.ClickhouseError, fn -> Error.reraise_or_wrap(e, []) end
    end

    test "reraises a non-client exception with its stacktrace intact" do
      e = %RuntimeError{message: "boom"}
      stack = [{:my_mod, :my_fun, 1, [file: "f.ex", line: 1]}]

      assert_raise RuntimeError, "boom", fn ->
        Error.reraise_or_wrap(e, stack)
      end
    end
  end
end
