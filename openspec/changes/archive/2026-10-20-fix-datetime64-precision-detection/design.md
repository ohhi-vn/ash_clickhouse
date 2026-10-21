# Design

## Context

See `proposal.md` — Why. What shapes the approach, observed in `lib/`:

- `Insert.encode_datetime/2` (`lib/ash_clickhouse/data_layer/insert.ex:275`) picks the wire form from the resolved ClickHouse column type: if `datetime64?(Types.resolve_attr_type(attr))` it emits a quoted decimal Unix-seconds string, otherwise `DateTime.to_unix(datetime, :second)`.
- `datetime64?/1` (`insert.ex:301`) is `defp datetime64?("DateTime64(" <> _), do: true`. That literal prefix matches `DateTime64(N)` and `DateTime64(N, 'UTC')`, but not the bare `DateTime64`.
- `Types.resolve_attr_type/1` (`lib/ash_clickhouse/data_layer/types.ex:124`) resolves an attribute's type to a ClickHouse type string: the built-in Ash datetime types all map to `"DateTime64(6)"` (`types.ex:45`, `types.ex:62-65`), while a custom type's `storage_type/1` string is returned verbatim. The bare `"DateTime64"` is therefore reachable only through a custom `storage_type/1`.
- `datetime64?/1` is private to `AshClickhouse.DataLayer.Insert` and is used only by `encode_datetime/2`, so widening it touches nothing else. `encode_datetime/2` is shared by the single-insert path (`do_insert/4` → `build_insert_rows/2`) and `bulk_create/3`, so both paths change identically.

The two facts that decide the shape of the fix, from ClickHouse itself:

- The `input_format_read_datetime_number_as_raw_value` setting "read[s] a bare unquoted integer for a DateTime / DateTime64 column as the raw underlying value — **seconds for DateTime**, ticks at the column precision for DateTime64 — instead of a Unix timestamp in seconds. Disabled by default: an unquoted number is a Unix timestamp in seconds (with optional sub-second precision) […] Enable it (or `SET compatibility = '26.7'`) to restore the behavior of versions up to and including 26.7, where a bare unquoted integer fed to a DateTime64 column was interpreted as the raw scaled value (ticks)." So for a `DateTime64` column the meaning of a bare integer flips with the server's version and settings; for a plain `DateTime` column it does not, because that column's raw underlying value *is* seconds.
- ClickHouse's `DateTime64` text parser reads up to the column's scale fractional digits and then discards the rest (`src/IO/ReadHelpers.h`, `readDateTimeTextImpl`: *"Ignore digits that are out of precision"*). A fixed six-digit fraction is therefore correct at every precision, and the column — not the encoder — decides the truncation.

## Goals / Non-Goals

**Goals:**

- Every `DateTime64` column, however it is declared, is encoded with the quoted decimal Unix-seconds string.
- The plain-`DateTime` integer form stays, with the reason it is safe recorded rather than deferred.

**Non-Goals:**

- Changing the wire form of any column that already receives the right one.
- Scaling the fractional part by the column's precision.
- The bulk *return* path — a separate change.
- The `Date`, `Time` and `Decimal` encodings, and the `NaiveDateTime` → `Etc/UTC` conversion.

## Decisions

### 1. Recognise the `DateTime64` type family by prefix, not by the `"DateTime64("` literal

The predicate becomes `String.starts_with?(type, "DateTime64")`, which covers `DateTime64`, `DateTime64(3)`, `DateTime64(6)` and `DateTime64(6, 'UTC')`.

Why not `type == "DateTime64"`: it would miss the timezone-suffixed forms, which the current `"DateTime64("` match already handles — a narrowing, not a fix.

Why not `String.starts_with?(type, "DateTime")`: `"DateTime64"` starts with `"DateTime"`, so that predicate would classify every `DateTime64` column as a plain `DateTime` — the same defect in the opposite direction. The predicate has to test for `"DateTime64"` specifically, and plain `DateTime` is then simply the remaining case, which is how `encode_datetime/2` already treats it.

**Alternative considered:** parse the type string into a precision and branch on it, as the 0.7.4 implementation did. Rejected — the encoder deliberately does not scale by precision, because the column truncates (see decision 2), and reintroducing a precision-dependent encoder is what the 0.7.4 → 0.7.5 → 0.7.7 sequence already cost.

### 2. Do not scale the fractional part by the column's precision

The encoder keeps emitting six fractional digits for every `DateTime64` column. ClickHouse's `DateTime64` text parser consumes up to the column's scale and discards the rest, so `DateTime64(3)` truncates `".123456"` to `".123"` on its own. One form covers every precision, and the encoder stays precision-independent.

**Alternative considered:** emit exactly `N` fractional digits for a `DateTime64(N)` column. Rejected — it makes the wire form depend on the column's declaration, which is what made the previous three releases disagree with each other.

### 3. Keep the plain-`DateTime` integer form, and record why it is safe

A bare integer for a plain `DateTime` column means the same number of seconds whether or not `input_format_read_datetime_number_as_raw_value` is enabled, because that setting reads the column's raw underlying value and a `DateTime` column's raw underlying value is seconds. The default reading is also seconds. The two coincide, so the form is unambiguous and the deferred risk from the 2026-10-09 design is closed as safe rather than carried forward.

**Alternative considered:** send plain `DateTime` as a quoted integer-seconds string, for symmetry with the `DateTime64` form. Rejected — it changes the wire form for a case that is already unambiguous, on a path with no test coverage of that specific form, for no behavioural gain. It is deliberately *not* the same as sending a quoted decimal string: a plain `DateTime` column has second precision and the text parser is not asked to truncate a fraction for it.

### 4. Keep the predicate private to `Insert`

`datetime64?/1` is used only by `encode_datetime/2`. It is not part of any public surface, so widening it needs no API decision.

## Risks / Trade-offs

- [A resource declaring a bare `DateTime64` column now writes a different wire form] → That is the intended fix. Under the default configuration the old bare integer was read as seconds and stored the right instant but truncated it to whole seconds; the new form stores the same instant with microsecond precision. Under `compatibility = '26.7'` or with the raw-value setting enabled, the old form stored the wrong instant and the new one stores the right one.
- [Rows written before the change are unaffected] → They were written under whatever configuration the server had at the time; this change does not rewrite them.
- [A custom type whose `storage_type/1` returns a string starting with `DateTime64` that is not a `DateTime64` column] → No such ClickHouse type name exists.
- [The `DateTime64` type family now includes `DateTime64` with no precision, whose ClickHouse default precision is 3] → The value is still written with six fractional digits and the column truncates to milliseconds, exactly as the requirement states for `DateTime64(3)`.

## Migration Plan

Ship as a patch release (version bump + `CHANGELOG.md` entry). No schema migration: the column type is unchanged and only the wire representation of the value changes. Rollback is reverting the change; rows written in the meantime need no repair, because the quoted decimal string and the bare integer are both accepted for the same column type, so the old form still reads them back.
