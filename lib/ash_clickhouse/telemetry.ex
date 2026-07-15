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

  Returns the result of `callback` directly. Exceptions raised inside `callback`
  are allowed to propagate: `:telemetry.span/3` catches them, emits the
  `[:ash_clickhouse, :query, :exception]` event, and reraises, so callers
  can translate the reraised error into an Ash-friendly error.
  """
  @spec span(Ash.Resource.t() | nil, atom(), String.t(), (-> term())) :: term()
  def span(resource, event, query, callback) do
    metadata = %{resource: resource, query: query, event: event}

    :telemetry.span([:ash_clickhouse, :query], metadata, fn ->
      result = callback.()

      # Surface success/failure in the :stop metadata so monitors can tell the
      # two apart. (Raised client errors are reported via the `:exception`
      # event instead, so this only reflects returned `{:error, _}` values.)
      status = if match?({:error, _}, result), do: :error, else: :ok

      {result, %{resource: resource, query: query, event: event, status: status}}
    end)
  end
end
