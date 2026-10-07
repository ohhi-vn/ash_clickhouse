# Tasks

## 1. Correct the bulk datetime encoder

- [x] 1.1 In `lib/ash_clickhouse/data_layer/insert.ex`, change `encode_datetime/2` so a `DateTime64` column returns `DateTime.to_unix(datetime, :microsecond) / 1_000_000` (fractional seconds) and a plain `DateTime` column keeps `DateTime.to_unix(datetime, :second)`; verify with `mix compile --warnings-as-errors`.
- [x] 1.2 Replace precision parsing (`parse_datetime64_precision/1` returning `{:precision, N}`/`:second`) with a `DateTime64` boolean predicate and delete the now-unused `scale_unix/2`; verify no compiler or Credo unused-function warnings (`mix credo --strict`).
- [x] 1.3 Confirm the `%NaiveDateTime{}` clause still converts via `DateTime.from_naive(value, "Etc/UTC")` and shares the fractional-seconds encoder; verify a `NaiveDateTime` and its UTC `DateTime` equivalent encode identically in a unit assertion.

## 2. Update unit tests that pinned the defective ticks

- [x] 2.1 Rewrite the `"DateTime64 precision scaling"` block in `test/unit/insert_test.exs` to assert fractional seconds for `(3)`/`(6)`/`(9)` and integer seconds for plain `DateTime`; verify `mix test test/unit/insert_test.exs`.
- [x] 2.2 Update the datetime assertions in `test/unit/coverage_gaps_test.exs` from `1_704_164_645_000_000` to the fractional-seconds value while keeping the plain-`DateTime` epoch-seconds expectation; verify `mix test test/unit/coverage_gaps_test.exs`.
- [x] 2.3 Add a unit case asserting the encoded `DateTime64(6)` value is a float and not an integer tick count, so a precision regression fails loudly; verify `mix test test/unit/insert_test.exs`.

## 3. Integration proof against ClickHouse

- [x] 3.1 In `test/integration/clickhouse_integration_test.exs`, extend the bulk-create coverage to write a raw `DateTime` through the bulk path into a `DateTime64(6)` column and read it back with exact microsecond equality; verify `mix test.integration` passes against a running ClickHouse and fails against the old tick encoding.

## 4. Verification, version, and downstream record

- [x] 4.1 Run the unit suite (`mix test --exclude integration`) and confirm green.
- [x] 4.2 Run `mix format --check-formatted` and `mix credo --strict` and confirm clean.
- [x] 4.3 Bump `mix.exs` to `0.7.5` and add a `CHANGELOG.md` entry stating that 0.7.4's scaled-tick `DateTime64` encoding never wrote values and 0.7.5 replaces it with fractional seconds; verify the version and entry are present.
- [x] 4.4 Record in the CHANGELOG or change notes that downstream `clickhouse_ex_logger` must raise its `ash_clickhouse` floor from `~> 0.7.4` to `~> 0.7.5` before its collapse can write timestamps; verify the note exists.
- [x] 4.5 Validate the planning artifacts with `openspec validate --change fix-bulk-datetime64-json-encoding --strict` and confirm no errors.
