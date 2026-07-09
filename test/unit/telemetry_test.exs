defmodule AshClickhouse.TelemetryTest do
  @moduledoc "Unit tests for AshClickhouse.Telemetry span contract."
  use ExUnit.Case, async: true

  alias AshClickhouse.Telemetry

  @event [:ash_clickhouse, :query, :stop]
  @start_event [:ash_clickhouse, :query, :start]
  @exception_event [:ash_clickhouse, :query, :exception]

  test "span returns the bare result of fun (contract-correct {result, %{}})" do
    result = Telemetry.span(MyResource, :read, "SELECT 1", fn -> 42 end)
    assert result == 42
  end

  test "span emits start and stop events with metadata" do
    test_pid = self()

    :telemetry.attach(
      "telemetry-test-#{:erlang.unique_integer()}",
      @start_event,
      fn _, _, meta, _ ->
        send(test_pid, {:start, meta})
      end,
      nil
    )

    :telemetry.attach(
      "telemetry-stop-#{:erlang.unique_integer()}",
      @event,
      fn _, _, meta, _ ->
        send(test_pid, {:stop, meta})
      end,
      nil
    )

    Telemetry.span(MyResource, :read, "SELECT 1", fn -> :ok end)

    assert_received {:start, start_meta}
    assert start_meta.resource == MyResource
    assert start_meta.query == "SELECT 1"
    assert_received {:stop, stop_meta}
    assert stop_meta.resource == MyResource
  after
    :telemetry.detach("telemetry-test-#{:erlang.unique_integer()}")
    :telemetry.detach("telemetry-stop-#{:erlang.unique_integer()}")
  end

  test "span lets exceptions propagate so the :exception event fires" do
    test_pid = self()
    ref = "telemetry-exc-#{:erlang.unique_integer()}"

    :telemetry.attach(
      ref,
      @exception_event,
      fn _, _, meta, _ ->
        send(test_pid, {:exception, meta})
      end,
      nil
    )

    assert_raise RuntimeError, "boom", fn ->
      Telemetry.span(MyResource, :read, "SELECT 1", fn -> raise "boom" end)
    end

    assert_received {:exception, _meta}
  after
    :telemetry.detach("telemetry-exc-#{:erlang.unique_integer()}")
  end
end
