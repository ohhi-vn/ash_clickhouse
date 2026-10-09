# Spec Delta

## MODIFIED Requirements

### Requirement: Bulk DateTime64 encoding uses fractional Unix seconds

The system SHALL encode `DateTime`/`NaiveDateTime` values for `DateTime64` columns as a quoted decimal Unix-seconds string carrying a microsecond fractional part (for example `"1704164645.123456"`), parsed by ClickHouse's date/time text parser. The form SHALL be timezone-independent and unaffected by numeric-input interpretation settings (such as `input_format_read_datetime_number_as_raw_value`). The column's own precision determines any truncation; microsecond resolution SHALL be preserved.

#### Scenario: DateTime64(6) encodes as fractional seconds

- **WHEN** a datetime is encoded for a `DateTime64(6)` column (the default for `:utc_datetime`, `:naive_datetime`)
- **THEN** the value is a JSON string of the form `"<whole-seconds>.<six-digit-microseconds>"` equal to that datetime's Unix instant, for example `"1704164645.123456"`, or `"1704164645.000000"` when it falls on a whole second

#### Scenario: A DateTime64 value never overflows the column

- **WHEN** a contemporary datetime is encoded for a `DateTime64(N)` column
- **THEN** the value is a quoted decimal-Unix-seconds string that ClickHouse accepts, rather than a JSON number whose meaning changes with the server version or input settings (raw ticks vs seconds)

#### Scenario: All DateTime64 precisions use the same fractional-seconds form

- **WHEN** a datetime is encoded for a `DateTime64(3)`, `DateTime64(6)`, or `DateTime64(9)` column
- **THEN** the value is a decimal-Unix-seconds string, identical in form across precisions, and the column's own precision determines any truncation

#### Scenario: Plain DateTime columns encode as integer seconds

- **WHEN** a datetime is encoded for a plain `DateTime` column (no precision suffix)
- **THEN** the value equals `DateTime.to_unix(datetime, :second)`

#### Scenario: NaiveDateTime converts via UTC before encoding

- **WHEN** a `NaiveDateTime` is encoded for a `DateTime64(N)` column
- **THEN** it is first interpreted as `Etc/UTC` and then encoded as a decimal-Unix-seconds string exactly as the equivalent `DateTime`

#### Scenario: Other bulk temporal encodings are unchanged

- **WHEN** bulk rows contain `Date` or `Time` values
- **THEN** `Date` encodes as days since `1970-01-01` and `Time` encodes as `"HH:MM:SS"`
