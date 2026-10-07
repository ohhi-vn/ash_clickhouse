# Spec Delta

## REMOVED Requirements

### Requirement: Bulk DateTime64 encoding respects column precision

**Reason**: This requirement defines bulk `DateTime64` encoding as raw scaled tick counts matched to column precision. ClickHouse's `FORMAT JSONCompactEachRow` input reads a `DateTime64` JSON number as seconds, not ticks, so the defined values overflow the column and never write. The behavior is nonfunctional, not merely imprecise.

**Migration**: Superseded by **Bulk DateTime64 encoding uses fractional Unix seconds**. Anything observing the encoded bulk rows should expect a fractional-seconds number instead of a per-precision integer tick count.

## ADDED Requirements

### Requirement: Bulk DateTime64 encoding uses fractional Unix seconds

The system SHALL encode bulk `DateTime`/`NaiveDateTime` values for `DateTime64` columns as fractional Unix seconds — a JSON number — because ClickHouse's `JSONCompactEachRow` input interprets a `DateTime64` JSON number as seconds. The value SHALL preserve microsecond resolution; sub-microsecond digits of a `DateTime64(9)` column are not represented by this form and are truncated.

#### Scenario: DateTime64(6) encodes as fractional seconds

- **WHEN** a datetime is encoded for a `DateTime64(6)` column (the default for `:utc_datetime`, `:naive_datetime`)
- **THEN** the value is a JSON number equal to `DateTime.to_unix(datetime, :microsecond) / 1_000_000`, preserving microseconds (for example `1_704_164_645.0`)

#### Scenario: A DateTime64 value never overflows the column

- **WHEN** a contemporary datetime is encoded for a `DateTime64(N)` column
- **THEN** the value is fractional Unix seconds and is accepted by ClickHouse, rather than an integer tick count that overflows the column range

#### Scenario: All DateTime64 precisions use the same fractional-seconds form

- **WHEN** a datetime is encoded for a `DateTime64(3)`, `DateTime64(6)`, or `DateTime64(9)` column
- **THEN** the value is fractional Unix seconds, identical in form across precisions, and the column's own precision determines any truncation

#### Scenario: Plain DateTime columns encode as integer seconds

- **WHEN** a datetime is encoded for a plain `DateTime` column (no precision suffix)
- **THEN** the value equals `DateTime.to_unix(datetime, :second)`

#### Scenario: NaiveDateTime converts via UTC before encoding

- **WHEN** a `NaiveDateTime` is encoded for a `DateTime64(N)` column
- **THEN** it is first interpreted as `Etc/UTC` and then encoded as fractional seconds exactly as the equivalent `DateTime`

#### Scenario: Other bulk temporal encodings are unchanged

- **WHEN** bulk rows contain `Date` or `Time` values
- **THEN** `Date` encodes as days since `1970-01-01` and `Time` encodes as `"HH:MM:SS"`
