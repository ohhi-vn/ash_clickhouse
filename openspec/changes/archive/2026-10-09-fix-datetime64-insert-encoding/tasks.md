# Tasks

## 1. Change the insert encoder

- [x] 1.1 In `lib/ash_clickhouse/data_layer/insert.ex`, change `encode_datetime/2` so a `DateTime64(...)` column returns a quoted decimal Unix-seconds string: build from `DateTime.to_unix(datetime, :microsecond)` as `<sign><whole-seconds>.<six-digit-microseconds>` (whole and fraction from the absolute value), for example `"1704164645.123456"`.
- [x] 1.2 Keep `NaiveDateTime` interpreted as `Etc/UTC` before encoding, keep plain `DateTime` columns as integer `DateTime.to_unix(datetime, :second)`, and leave `Date`, `Time`, and the `datetime64?/1` predicate unchanged.

## 2. Update unit tests

- [x] 2.1 Update the `insert_test.exs` "DateTime64 precision scaling" block to assert string values: `"1704164645.000000"` for a whole second, `"1704164645.123456"` for microsecond precision, `is_binary/1`, and that a `NaiveDateTime` encodes identically to its UTC `DateTime`.
- [x] 2.2 Update `coverage_gaps_test.exs` (`encode_bulk_value` cases) to expect `[[nil, "1704164645.000000"]]` for the `DateTime64(6)` column, keeping the plain-`DateTime` integer-seconds assertion.
- [x] 2.3 Add a unit case covering a pre-1970 datetime (negative epoch) and a non-6 precision (`DateTime64(3)` and/or `DateTime64(9)`) to pin the sign handling and precision-independent form.

## 3. Verify against a real ClickHouse

- [x] 3.1 Run the `bulk_datetimes` integration round-trip (`test/integration/clickhouse_integration_test.exs`) against a container; confirm `~U[2024-01-02 03:04:05.123456Z]` is written and read back exactly, with no `Code: 407` on the async insert. Verified in direct-connect mode against a running ClickHouse `26.9.1.1629` (the failing version): `bulk_datetimes` passed (`1 passed, 16 excluded`). A raw probe reproduced the reported `Code: 407 ... Numeric value is out of range for DateTime64 ... While executing WaitForAsyncInsert` for the integer-microsecond form, while the quoted decimal-Unix-seconds string stored `1704164645123456` exactly, including under `input_format_read_datetime_number_as_raw_value=1`.
- [x] 3.2 Confirm the single-`create` path (`do_insert/3`) writes the same value, since it shares `build_insert_rows/2`. Verified in `lib/ash_clickhouse/data_layer.ex:745-755` — `do_insert/3` builds rows via `Insert.attrs_to_row/2` → `Insert.build_insert_rows/2`, the same encoder as `bulk_create/3`.

## 4. Release bookkeeping

- [x] 4.1 Bump the patch version in `mix.exs` and add a `CHANGELOG.md` entry describing the decimal-Unix-seconds string encoding and the `DateTime64` `Code: 407` failure it fixes. (0.7.6 → 0.7.7)

## 5. Verification

- [x] 5.1 Run `mix format` and the unit suite (`mix test test/unit`); run the integration suite when a container engine is available. `mix format` on changed files and `mix test test/unit` (570 passed) succeeded; the integration suite ran against a live ClickHouse `26.9.1.1629` in direct-connect mode — 31 integration tests: 29 passed, 1 skipped, and the 2 failures (`clickhouse_integration_complex_test.exs:348` and `:437`) reproduce on the pre-change encoder, so they are pre-existing and unrelated.
