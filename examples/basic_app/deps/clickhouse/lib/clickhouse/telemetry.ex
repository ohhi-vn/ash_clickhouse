defmodule ClickHouse.Telemetry do
  @moduledoc """
  ClickHouse produces multiple telemetry events.

  ## Events

  * `[:clickhouse, :init, :start]` - Called when a ClickHouse client init starts.

    #### Measurements
      * `:system_time` - The current monotonic system time.

    #### Metadata
      * `:client` - The name of the client.

  * `[:clickhouse, :init, :stop]` - Called when a ClickHouse client init stops.

    #### Measurements
      * `:duration` - The amount of time taken to start the ClickHouse client.

    #### Metadata
      * `:client` - The name of the client.

  * `[:clickhouse, :init, :exception]` - Called when a ClickHouse client init has an exception.

    #### Measurements
      * `:duration` - The amount of time before the error occurred.

    #### Metadata
      * `:client` - The name of the client.
      * `:kind` - The kind of error raised.
      * `:reason` - The reason for the error.
      * `:stacktrace` - The stacktrace of the error.

  * `[:clickhouse, :prepare, :start]` - Called when a ClickHouse query preparation starts.

    #### Measurements
      * `:system_time` - The current monotonic system time.

    #### Metadata
      * `:client` - The name of the client.

  * `[:clickhouse, :prepare, :stop]` - Called when a ClickHouse query preparation stops.

    #### Measurements
      * `:duration` - The amount of time taken to prepare the query.

    #### Metadata
      * `:client` - The name of the client.

  * `[:clickhouse, :prepare, :exception]` - Called when a ClickHouse query preparation has an exception.

    #### Measurements
      * `:duration` - The amount of time before the error occurred.

    #### Metadata
      * `:client` - The name of the client.
      * `:kind` - The kind of error raised.
      * `:reason` - The reason for the error.
      * `:stacktrace` - The stacktrace of the error.

  * `[:clickhouse, :execute, :start]` - Called when a ClickHouse query execution starts.

    #### Measurements
      * `:system_time` - The current monotonic system time.

    #### Metadata
      * `:client` - The name of the client.

  * `[:clickhouse, :execute, :stop]` - Called when a ClickHouse query execution stops.

    #### Measurements
      * `:duration` - The amount of time taken to execute the query.

    #### Metadata
      * `:client` - The name of the client.

  * `[:clickhouse, :execute, :error]` - Called when a ClickHouse query execution has an error.

    #### Metadata
      * `:client` - The name of the client.
      * `:error` - The error that occured.

  * `[:clickhouse, :execute, :exception]` - Called when a ClickHouse query execution has an exception.

    #### Measurements
      * `:duration` - The amount of time before the error occurred.

    #### Metadata
      * `:client` - The name of the client.
      * `:kind` - The kind of error raised.
      * `:reason` - The reason for the error.
      * `:stacktrace` - The stacktrace of the error.
  """

  @compile {:inline, span: 3, error: 3}

  if Code.ensure_loaded?(:telemetry) do
    @doc false
    @spec span(name :: atom(), meta :: map(), (-> {any, map})) :: any()
    def span(name, meta, fun) do
      :telemetry.span([:clickhouse, name], meta, fun)
    end

    @doc false
    @spec error(name :: atom(), error :: any(), meta :: map()) :: :ok
    def error(name, error, meta) do
      :telemetry.execute([:clickhouse, name, :error], %{}, Map.put(meta, :error, error))
    end
  else
    @doc false
    @spec span(name :: atom(), meta :: map(), (-> {any, map})) :: any()
    def span(_, _, span_fn), do: elem(span_fn.(), 0)

    @doc false
    @spec error(name :: atom(), error :: any(), meta :: map()) :: :ok
    def error(_, _, _), do: :ok
  end
end
