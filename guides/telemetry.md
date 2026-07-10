# Telemetry

AshClickhouse emits telemetry around every query executed against ClickHouse via
`AshClickhouse.Telemetry`.

## Events

All events are prefixed with `[:ash_clickhouse, :query]`:

| Event | Emitted when |
| --- | --- |
| `[:ash_clickhouse, :query, :start]` | A query is about to run |
| `[:ash_clickhouse, :query, :stop]` | A query completed successfully |
| `[:ash_clickhouse, :query, :exception]` | A query raised an error |

These mirror the structure used by other Ash data layers, so existing Ash
telemetry tooling and dashboards can consume them.

## Metadata

Each event carries the following metadata:

- `:resource` — the Ash resource (or `nil`)
- `:query` — the SQL query string
- `:event` — the event atom (e.g. `:run_query`)

The `:stop` and `:exception` events also include the result/error in the
standard `:telemetry.span/3` measurement and result tuples.

## Attaching a handler

```elixir
:telemetry.attach(
  "ash-clickhouse-logger",
  [:ash_clickhouse, :query, :stop],
  fn _event, _measure, meta, _config ->
    Logger.debug("ClickHouse query on #{inspect(meta.resource)}: #{meta.query}")
  end,
  nil
)
```

## How it works

`AshClickhouse.Telemetry.span/4` wraps the query function with
`:telemetry.span/3`. Exceptions raised inside the function are caught by the
span, the `:exception` event is emitted, and the error is reraised so the data
layer can translate it into an `AshClickhouse.Error.ClickhouseError`.
