defmodule AshClickhouse.Telemetry do
  @moduledoc """
  Telemetry helpers for AshClickhouse.

  Emits `[:ash_clickhouse, :query, :start | :stop | :exception]` events around
  every query executed against ClickHouse, mirroring the structure used by
  Ash data layers.
  """

  require Logger

  @doc """
  Spans a query execution, emitting telemetry start/stop/exception events.

  Returns the result of `fun`, or re-raises after emitting an exception event.
  """
  @spec span(Ash.Resource.t() | nil, atom(), String.t(), (() -> term())) :: term()
  def span(resource, event, query, fun) do
    metadata = %{resource: resource, query: query}
    :telemetry.span([:ash_clickhouse, :query, event], metadata, fn -> safe_run(fun) end)
  end

  defp safe_run(fun) do
    try do
      {:ok, fun.()}
    rescue
      e ->
        {:error, e}
    end
  end
end
