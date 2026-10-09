# Design

## Context

See `proposal.md` — Why. What shapes the approach, observed in `lib/ash_clickhouse/data_layer/insert.ex`:

- One encoder serves every write. `build_insert_rows/2` maps each attribute through `encode_bulk_value/3`, which dispatches `%DateTime{}`/`%NaiveDateTime{}` to `encode_datetime/2`. Both `do_insert/3` (single `create`) and `bulk_create/3` build their rows this way, so the two paths share one wire format. (The prior change's design claimed the single-row path used `?` placeholders and was unaffected; that is not true — `do_insert/3` calls `repo.insert_rows/3` with the same `JSONCompactEachRow` statement.)
- `encode_datetime/2` decides the wire unit from `Types.resolve_attr_type/1`, which resolves NewTypes and custom `storage_type/1` to a ClickHouse type string such as `"DateTime64(6)"` or a plain `"DateTime"`.
- ClickHouse's numeric JSON handling of `DateTime64` is not stable: 26.8 changed a bare JSON integer from raw ticks to Unix seconds, and `input_format_read_datetime_number_as_raw_value = 1` restores the old reading. `0.7.4` sent microsecond ticks; `0.7.5` sent fractional seconds; both are JSON numbers, so both are exposed to that interpretation.
- ClickHouse's text path is stable: `readDateTime64Text` (used by `date_time_input_format = 'basic'`) and `parseDateTime64BestEffort` (the `best_effort` default) both parse a quoted decimal Unix timestamp, with the fractional part carrying the precision.
- Elixir `DateTime` carries at most microsecond resolution (`10^-6`).

## Goals / Non-Goals

**Goals:**

- Make `DateTime64` inserts deterministic: one wire form whose meaning does not depend on the ClickHouse version or numeric-input settings.
- Preserve the instant and its microsecond precision, independent of the column's declared precision `N`.
- Keep the change inside the encoder; no signature, DSL, or public API change.

**Non-Goals:**

- Changing the parameterised mutation/filter paths (`ALTER TABLE ... UPDATE`, `WHERE` clauses), reads, streams, or aggregates.
- Representing sub-microsecond precision for `DateTime64(8)`/`DateTime64(9)` — the source `DateTime` cannot carry it.
- Changing plain-`DateTime`, `Date`, or `Time` wire forms.
- Re-introducing per-precision scaling; the column truncates.

## Decisions

### 1. Send `DateTime64` as a quoted decimal Unix-seconds string

`encode_datetime/2` returns a string `"<whole-seconds>.<six-digit-microseconds>"` for a `DateTime64` column, built from the signed epoch microseconds:

- `micros = DateTime.to_unix(datetime, :microsecond)`
- sign, `whole = div(abs(micros), 1_000_000)`, `frac = rem(abs(micros), 1_000_000)` padded to six digits.

Example: `~U[2024-01-02 03:04:05.123456Z]` → `"1704164645.123456"`.

Why: ClickHouse's date/time text parser consumes this form deterministically. `readDateTime64Text` reads the integer part as Unix seconds and the `.` fraction as sub-second digits; `parseDateTime64BestEffort` does the same. Neither consults `input_format_read_datetime_number_as_raw_value`, and both are reached for a JSON *string* regardless of the JSON number path. The value is an absolute Unix instant, so it is independent of the column/server timezone.

Alternatives considered:

- **Keep the fractional JSON number (0.7.5).** This is the defect: on affected servers the number is rejected (`Code: 407`) or the meaning flips with version/settings.
- **ISO-8601 string (`"2024-01-02T03:04:05.123456Z"`).** Readable, but only the `best_effort` parser accepts the `T`/`Z`/offset shape; a deployment on `date_time_input_format = 'basic'` would reject it. The decimal form is accepted by both parsers, so it is strictly more portable.
- **Scaled integer ticks as a string.** Relies on the parser's `whole >= 253402300800` heuristic to reinterpret a large number as already-scaled; an implicit contract rather than a documented one, and version-sensitive.
- **Per-precision fractional digits.** Unnecessary: the column truncates, and emitting a fixed six-digit fraction keeps the encoder precision-independent.

### 2. Always emit six fractional digits; let the column truncate

The fraction is the datetime's microsecond field padded to six digits, for every `DateTime64(N)`. `DateTime64(0)` ignores the fraction; `DateTime64(3)` truncates it; `DateTime64(9)` scales it up (`.123456` → `.123456000`). A whole-second instant renders as `.000000`. This keeps `encode_datetime/2` free of precision parsing and matches the prior design's "column decides truncation" contract.

### 3. Leave plain `DateTime` columns as integer Unix seconds

A plain `DateTime` column maps to `"DateTime"` and currently encodes as `DateTime.to_unix(datetime, :second)`. It is not part of the reported failure and the integer-seconds reading is the documented one for `DateTime`, so it stays unchanged to keep the diff and the compatibility surface minimal. (The same numeric-interpretation risk exists in principle; if it ever materialises, the same string treatment would apply, tracked as a follow-up rather than scope creep.)

### 4. Cover both insert paths with the one change

Because `do_insert/3` and `bulk_create/3` share `encode_datetime/2`, the single-`create` failure in the report (e.g. `Activity.create_activity`) and bulk writes are fixed together. No second code path needs editing.

## Risks / Trade-offs

- **A string value could be rejected by a non-standard `date_time_input_format`.** → Both shipped parsers (`basic`, `best_effort`, plus `best_effort_us`) accept a decimal Unix timestamp; the tests pin the encoded string and the integration test writes and reads a row back.
- **Pre-1970 (`negative`) instants.** → Formatting from signed epoch microseconds with `div`/`rem` on the absolute value yields `-1.123456`-style strings, which ClickHouse's `DateTime64` text parser already handles (negative whole + fraction). Covered by a unit case.
- **Column precision truncation changes an asserted value.** → Unit assertions compare the produced string, not a stored column; integration asserts the `DateTime64(6)` round trip so truncation beyond microseconds is not expected.
- **A future caller relies on the old numeric type.** → The encoder's output is internal to `build_insert_rows/2`; the public building blocks and their signatures are unchanged.
- **Plain `DateTime` still uses a JSON number.** → Accepted; not implicated in the report, documented as a deliberate boundary.

## Migration Plan

Ship as a patch release (version bump + `CHANGELOG.md`). No schema or API migration: the stored instant is unchanged, only the wire representation. Rollback is reverting `encode_datetime/2`; because the new form is a superset of accepted input, a rollback does not require data repair.
