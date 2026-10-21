# Tasks

## 1. Widen the DateTime64 column-type detection

- [x] 1.1 In `lib/ash_clickhouse/data_layer/insert.ex`, change `datetime64?/1` so it recognises the `DateTime64` type family — `DateTime64`, `DateTime64(N)` and `DateTime64(N, 'UTC')` — instead of the `"DateTime64("` literal, and verify `mix compile --warnings-as-errors` reports no warnings.
- [x] 1.2 In `test/unit/insert_test.exs`, add a type whose `storage_type/1` returns the bare `"DateTime64"` and an attribute for it on `PrecisionResource`, and verify the "DateTime64 decimal Unix-seconds encoding" block asserts the decimal string `"1704164645.123456"` for that attribute rather than the integer `1704164645`.
- [x] 1.3 Verify the existing assertions in that block still hold — `DateTime64(3)` and `DateTime64(9)` produce the same decimal string, and the plain-`DateTime` attribute still produces the integer epoch seconds — and verify the single-insert path, which shares `encode_datetime/2`, is unaffected by running the insert unit tests.

  **Note on 1.2:** `PrecisionResource` gained a `default_precision` attribute, so the four positional assertions in the block gained a trailing element. The new attribute is asserted by a dedicated case, "a DateTime64 column declared without a precision is still a DateTime64 column". Verified that the new cases **fail against the old matcher** (reverting `datetime64?/1` gives 2 failures) and pass with the widened one.

## 2. Verify against a real ClickHouse

- [x] 2.1 Run the `bulk_datetimes` integration round-trip (`test/integration/clickhouse_integration_test.exs`) against a container; verify `~U[2024-01-02 03:04:05.123456Z]` is written and read back exactly, with no `Code: 407` on the insert — the bare-`DateTime64` column produces the same wire form as `DateTime64(6)`, so this confirms the widened detection did not disturb the accepted form.
- [x] 2.2 Confirm the bare-`DateTime64` column's stored value is truncated by the column, not by the encoder: verify the value written for a `DateTime64` column carries six fractional digits on the wire and is stored to the column's own precision.

  **Note on 2.1/2.2:** no container engine was available, but a ClickHouse **26.9.20.23** was reachable on `http://localhost:8123`, so the integration suite was run in direct-connect mode: `CLICKHOUSE_DIRECT=1 CLICKHOUSE_URL=http://localhost:8123 mix test test/integration/clickhouse_integration_test.exs --include integration` → **16 passed, 1 skipped**, including the `bulk_datetimes` `DateTime64(6)` round-trip.

  A bare `DateTime64` in ClickHouse resolves to `DateTime64(3)`. A resource whose type declares `storage_type/1` returning `"DateTime64"` was inserted through the library's own path into such a column, and the old and new encoders were compared side by side on the same server:

  | encoder | default settings | `input_format_read_datetime_number_as_raw_value=1` |
  |---|---|---|
  | old — bare integer `1704164645` | `2024-01-02 03:04:05.000` | **`1970-01-20 17:22:44.645`** |
  | new — quoted decimal `"1704164645.123456"` | `2024-01-02 03:04:05.000` | `2024-01-02 03:04:05.000` |

  So the old form silently dropped the microseconds *and* stored a completely different instant when the numeric-input setting (or `compatibility = '26.7'`) is in effect — the value read as raw ticks at the column's precision. The new form stores the same instant under both configurations, truncated to the column's own precision by ClickHouse (milliseconds here), not by the encoder. The probe table was dropped afterwards.


## 3. Release bookkeeping

- [x] 3.1 Bump the patch version in `mix.exs` and add a `CHANGELOG.md` entry naming the failure the fix removes — a `DateTime64` column declared without an explicit precision being written as a bare integer number of seconds, whose meaning changes with the server version and with `input_format_read_datetime_number_as_raw_value`, and which silently lost its microseconds.
- [x] 3.2 Run `mix format` on the changed files and the unit suite (`mix test test/unit`); verify the suite passes with no new failures and that `mix format --check-formatted` reports no diff.

  **Note on 3.2:** the unit suite is **583 passed, 0 failed**. `mix format --check-formatted` over the project inputs fails on `test/support/._test_resource.ex` — a macOS AppleDouble file (gitignored via `._*`, untracked) that the external volume generates; it is environmental, not source. Every tracked source file under the formatter inputs is clean. The integration suite, run in direct-connect mode against the local ClickHouse 26.9.20.23, is **29/31 passed, 1 skipped**, with the same 2 failures in `clickhouse_integration_complex_test.exs` that the 0.7.7 changelog already recorded as pre-existing — they reproduce identically on the pre-change code (verified by stashing the change and re-running: 13/15, same 2 failures) and are in the **single-`create** path, which this change does not touch.

