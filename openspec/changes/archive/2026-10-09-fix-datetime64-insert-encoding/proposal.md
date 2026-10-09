# Proposal

## Why

`0.7.5` encodes `DateTime64` insert values as fractional Unix-second JSON *numbers*. ClickHouse does not treat a `DateTime64` JSON number as an unambiguous instant: the meaning changed in 26.8 (bare integers moved from raw ticks to seconds) and can be toggled with `input_format_read_datetime_number_as_raw_value`, so on affected 26.9 servers the value is rejected with `Code: 407 DECIMAL_OVERFLOW` / `Numeric value is out of range for DateTime64` while ClickHouse reads the async-insert buffer. The failure surfaces on resource creates (for example `StorageService.UserStats.Activity.create_activity`), so timestamp writes are broken for those servers. A quoted string is parsed by ClickHouse's date/time text parser and is not subject to the numeric-interpretation changes.

## What Changes

- Encode `DateTime`/`NaiveDateTime` values for `DateTime64(N)` columns as a **quoted decimal Unix-seconds string** (for example `"1704164645.123456"`) instead of a JSON number. The string is timezone-independent and preserves microsecond resolution; the column's own precision decides any truncation.
- Keep plain `DateTime` columns (no precision suffix) as integer epoch seconds.
- Keep the `NaiveDateTime` → `Etc/UTC` conversion; it then shares the new string encoder.
- Keep `Date` (days since `1970-01-01`) and `Time` (`"HH:MM:SS"`) encodings unchanged.
- Update the `bulk-create` datetime-encoding requirement and the unit tests that assert the fractional-number form.
- No DSL, repo API, schema, or dependency change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `bulk-create`: the **Bulk DateTime64 encoding** requirement changes from "fractional Unix seconds — a JSON number" to "a quoted decimal Unix-seconds string", because ClickHouse's numeric JSON interpretation of `DateTime64` is version- and setting-dependent.

## Impact

- **Code**: `AshClickhouse.DataLayer.Insert` — `encode_datetime/2` emits the decimal-Unix-seconds string for `DateTime64` columns (shared by both the single-insert and `bulk_create` paths, which both build rows via `build_insert_rows/2`).
- **Tests**: `test/unit/insert_test.exs` (DateTime64 precision scaling block) and `test/unit/coverage_gaps_test.exs` (bulk encoding cases) assert the old number form and must be updated; the integration round-trip test covers the string form.
- **Release**: patch version bump and `CHANGELOG.md` entry.
- **APIs/dependencies**: no public API change; `clickhouse ~> 0.32` and `ash ~> 3.33` unchanged.
