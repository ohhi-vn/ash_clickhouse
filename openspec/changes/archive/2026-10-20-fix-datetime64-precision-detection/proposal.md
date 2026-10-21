# Proposal

## Why

The encoder decides between the `DateTime64` form and the plain-`DateTime` form by matching the literal prefix `"DateTime64("` against the resolved ClickHouse column type (`lib/ash_clickhouse/data_layer/insert.ex:301`). A `DateTime64` column declared **without** an explicit precision — `DateTime64`, whose ClickHouse default precision is 3 — does not match that prefix, so it falls through to the plain-`DateTime` branch and is encoded as a bare JSON **integer** number of seconds.

That is the exact form the encoding work removed because ClickHouse's numeric interpretation of a `DateTime64` value is not stable: a bare unquoted integer is read as Unix seconds by default, but as raw ticks when `input_format_read_datetime_number_as_raw_value` is enabled or `compatibility = '26.7'` is set. Under those configurations the value written to the column is not the instant that was submitted. The value also silently loses its microseconds, because integer seconds carry none.

The declaration is reachable through a documented extension point: a resource whose attribute type implements `storage_type/1` and returns `"DateTime64"` (`Types.resolve_attr_type/1` returns that string verbatim). Observed:

```
WIRE (custom storage_type "DateTime64", no precision): [["c5f4500a-...", 1704164645]]
```

The `bulk-create` requirement already says the encoding for `DateTime64` columns is a quoted decimal Unix-seconds string, and its "All DateTime64 precisions use the same fractional-seconds form" scenario enumerates `DateTime64(3)`, `DateTime64(6)` and `DateTime64(9)` — but not the no-precision declaration, so the omission reads as permitted.

## What Changes

- A `DateTime64` column is recognised as a `DateTime64` column whatever its declaration — with an explicit precision, without one, or with a timezone suffix — and is encoded as the quoted decimal Unix-seconds string, like every other `DateTime64` column.
- Plain `DateTime` columns keep integer epoch seconds. The bare integer is safe there and the requirement now says so: a `DateTime` column's raw underlying value *is* seconds, so `input_format_read_datetime_number_as_raw_value` does not change what the number means.
- The `bulk-create` requirement's precision scenario is extended to cover the no-precision declaration, so the omission that let the gap through is closed.

Explicit non-goals:

- No change to what is written for `DateTime64(3)`, `DateTime64(6)` or `DateTime64(9)` columns — those already use the fractional-seconds form and keep using it.
- No change to the `Date`, `Time` or `Decimal` encodings, to the `NaiveDateTime` → `Etc/UTC` conversion, or to the plain-`DateTime` integer form.
- The bulk *return* path is not touched here; it is fixed by a separate change.
- No DSL, repo API, schema, or dependency change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `bulk-create`: the **Bulk DateTime64 encoding** requirement's precision scenario is extended to cover a `DateTime64` column declared without an explicit precision, and a scenario is added pinning that the plain-`DateTime` integer form is unaffected by numeric-input interpretation settings.

## Impact

- **Code**: `AshClickhouse.DataLayer.Insert` — `datetime64?/1` (`insert.ex:301`) recognises the `DateTime64` type family rather than the `"DateTime64("` prefix. The predicate is used only by `encode_datetime/2` (`insert.ex:275`), which the single-insert and `bulk_create` paths share, so both paths are affected identically.
- **Tests**: `test/unit/insert_test.exs` already defines types for `DateTime64(3)`, `DateTime64(9)` and plain `DateTime`; a type whose `storage_type/1` returns the bare `"DateTime64"` is added, and the existing precision-scaling block is extended to cover it.
- **Release**: patch version bump and `CHANGELOG.md` entry.
- **APIs/dependencies**: no public API change; `clickhouse ~> 0.32` and `ash ~> 3.33` unchanged.
