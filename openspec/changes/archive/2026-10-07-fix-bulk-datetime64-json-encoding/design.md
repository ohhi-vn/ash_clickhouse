# Design

## Context

See `proposal.md` — Why for motivation. What shapes the approach, observed in `lib/ash_clickhouse/data_layer/insert.ex`:

- The bulk path encodes values in `encode_bulk_value/3`, which dispatches `%DateTime{}`/`%NaiveDateTime{}` to `encode_datetime/2`. That function parses `DateTime64(N)` from `Types.resolve_attr_type/1` and returns `DateTime.to_unix/2` scaled to `10^N` ticks (`:millisecond`/`:microsecond`/`:nanosecond`/`scale_unix/2`). This is the defective half of 0.7.4.
- The single-row path (`encode_attr_value/4` → `Types.encode_value/2`) uses parameterised `?` placeholders and is unaffected: the overflow is specific to `FORMAT JSONCompactEachRow` numeric input.
- `Types.ash_type_to_clickhouse/1` maps `:utc_datetime`, `:utc_datetime_usec`, `:naive_datetime`, `:naive_datetime_usec`, and `Ash.Type.DateTime` to `"DateTime64(6)"`; a custom `storage_type/1` may return `"DateTime64(N)"` or a plain `"DateTime"` (see `coverage_gaps_test.exs`'s `PlainSecondDateTime`).
- The `bulk-create` spec currently requires raw scaled ticks; that requirement is the contract this change modifies.

## Goals / Non-Goals

**Goals:**

- Make bulk `DateTime64` writes succeed against a real ClickHouse by emitting a JSON value its input parses as a datetime.
- Keep the change confined to the bulk encoder; no signature or spec shape change beyond the datetime-encoding requirement.

**Non-Goals:**

- Changing the single-row `create/update/destroy` path, reads, streams, or aggregates.
- Preserving nanoseconds for `DateTime64(9)` (a float JSON number cannot carry nanoseconds at epoch scale; accepted, see Risks).
- Changing client-option sanitization (the correct half of 0.7.4) or the `Date`/`Time` encodings.
- Editing `clickhouse_ex_logger`; its collapse change is a downstream consumer, recorded under Impact.

## Decisions

### 1. Encode `DateTime64` as fractional Unix seconds

`encode_datetime/2` returns `DateTime.to_unix(datetime, :microsecond) / 1_000_000` for a `DateTime64` column. ClickHouse's `JSONCompactEachRow` input reads a `DateTime64` JSON number as **seconds** (verified: integer microseconds → `Code: 407 DECIMAL_OVERFLOW`; fractional seconds → accepted, microseconds preserved), so the value must be seconds, and a fractional number is how sub-second precision survives.

- **Why not raw scaled ticks:** that is the 0.7.4 defect; ticks are not the JSON-number unit.
- **Alternative considered — ISO-8601 string:** also accepted and able to carry up to nanoseconds, but it makes the encoding a string whose exact accepted format (space vs `T`, offset vs `Z`) is server-dependent, and it would round-trip through a different JSON type. The team chose fractional seconds for simplicity and microsecond fidelity; if nanosecond writes are ever required, the string form is the escape hatch and would be a follow-up.
- **Alternative considered — keep per-precision precision:** unnecessary; the JSON seconds form is precision-independent and the column truncates server-side. Scaling per precision would encode the same instant differently for no benefit.

### 2. Reduce precision parsing to a `DateTime64` predicate

Replace `parse_datetime64_precision/1` (three clauses returning `{:precision, N}` / `:second`) and delete `scale_unix/2`, leaving a boolean check (`"DateTime64(" <> _`). A `DateTime64` column → fractional seconds; a plain `DateTime` column → integer `DateTime.to_unix(dt, :second)`, unchanged. Rationale: the only remaining distinction that affects the wire value is DateTime64 vs not.

### 3. Keep `NaiveDateTime` conversion and public building blocks stable

`NaiveDateTime` keeps the existing `DateTime.from_naive(v, "Etc/UTC")` step and shares the new encoder. `encode_datetime/2` stays private and `build_insert_rows/2`'s signature is unchanged, so downstream callers of the building blocks see only the corrected values.

### 4. Ship as patch `0.7.5`

The 0.7.4 wire form never successfully wrote a timestamp, so this is a behavioural bug fix, not a new capability. Bump `mix.exs` and record it in `CHANGELOG.md`; downstream `clickhouse_ex_logger` should raise its floor from `~> 0.7.4` to `~> 0.7.5` when it re-validates its collapse.

## Risks / Trade-offs

- **`DateTime64(9)` sub-microsecond digits are lost.** A JSON double has ~15–16 significant decimal digits; at a ~1.7×10⁹-second epoch, resolution is marginally under a microsecond, so nanoseconds cannot be represented. → Accepted and stated in the spec; a host needing nanoseconds would require the ISO-string form, tracked as a possible follow-up, not a blocker (the logger's column is `DateTime64(6)`).
- **Float-to-JSON rendering could use scientific notation.** E.g. a far-future epoch rendered as `1.7e9`. → Jason renders contemporary epoch seconds as a plain decimal; the integration test asserts a written row reads back with the exact microsecond value, which would fail loudly on a rendering incompatibility.
- **A precision regression could silently reintroduce ticks.** → Unit tests assert the fractional-seconds value distinct from the old integer, and an integration test writes a real row and reads it back.
- **Encoding an out-of-range instant.** → Unchanged from today: out-of-range datetimes still surface as the server's error; this change does not add validation.
