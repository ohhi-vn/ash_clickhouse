# Proposal

## Why

The archived `fix-bulk-create-write-path` change, shipped in 0.7.4, claimed bulk `DateTime64` encoding was fixed by emitting raw scaled *ticks* (microseconds for `DateTime64(6)`). That premise is false: ClickHouse's `FORMAT JSONCompactEachRow` input reads a `DateTime64` JSON *number* as **seconds**, so a microsecond integer is astronomically out of range and every timestamp write fails with `Code: 407 DECIMAL_OVERFLOW`. Verified directly against the suite's ClickHouse 26.9.10.4: an integer microsecond value overflows, while a fractional-seconds number is accepted and preserves full microseconds. The option-sanitization half of 0.7.4 is correct and is not touched. Downstream `clickhouse_ex_logger` removed its ISO-8601 timestamp workaround on the false premise, so the collapse it planned cannot write timestamps until this is corrected upstream.

## What Changes

- Encode bulk `DateTime64(N)` values as **fractional Unix seconds** (a JSON number), the form ClickHouse's JSON input actually interprets as a datetime. This replaces the raw scaled-tick encoding for every precision `N`.
- Keep plain `DateTime` columns (no precision suffix) as integer epoch seconds, and `Date`/`Time` bulk encodings unchanged.
- `NaiveDateTime` keeps its `Etc/UTC` conversion and then uses the same fractional-seconds form.
- Remove the per-precision tick scaler (`scale_unix/2`) and precision parsing now that the JSON form is precision-independent; detection of "is this a `DateTime64` column" replaces it.
- Update the `bulk-create` spec's datetime-encoding requirement and the unit tests that currently assert the defective integer ticks.
- No DSL, repo API, or schema change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `bulk-create`: the **Bulk DateTime64 encoding respects column precision** requirement changes from "raw scaled `DateTime64` ticks matching the resolved precision" to "fractional Unix seconds", because ClickHouse's JSON input interprets a `DateTime64` number as seconds.

## Impact

- **Code**: `AshClickhouse.DataLayer.Insert` — `encode_datetime/2` emits fractional seconds; `parse_datetime64_precision/1` and `scale_unix/2` are removed or reduced to a `DateTime64` predicate.
- **Tests**: `test/unit/insert_test.exs` (DateTime64 precision scaling block) and `test/unit/coverage_gaps_test.exs` (bulk encoding fallbacks) assert the old integer ticks and must be updated.
- **Downstream**: unblocks `clickhouse_ex_logger`'s in-flight `collapse-insert-to-ash-bulk-create` change, which removed its ISO-8601 timestamp workaround assuming 0.7.4 handled it.
- **APIs/dependencies**: no public API change; `clickhouse ~> 0.32` and `ash ~> 3.33` unchanged; ClickHouse server behaviour unchanged.
