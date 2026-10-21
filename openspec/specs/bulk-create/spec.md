# bulk-create Specification

## Purpose

Makes Ash bulk inserts a reliable write path to ClickHouse so callers can use `Ash.bulk_create/4` directly instead of a downstream workaround module.

## Requirements

### Requirement: Bulk create forwards only ClickHouse-recognized insert options

The system SHALL sanitize options before calling the ClickHouse client so Ash-internal bulk keys never reach the client.

#### Scenario: Ash bulk keys are stripped

- **WHEN** `bulk_create` is invoked with Ash keys such as `return_records?`, `batch_size`, `return_errors?`, `authorize?`, `tenant`, `tracer`, `action`, or `resource`
- **THEN** none of those keys appears in the keyword list passed to `repo.insert_rows/3`

#### Scenario: Configured insert options still apply

- **WHEN** a resource configures `insert_opts` (e.g. `async_insert`, `wait_for_async_insert`)
- **THEN** those configured values are forwarded to `repo.insert_rows/3`

#### Scenario: Explicit caller insert flags still apply

- **WHEN** the caller passes `async_insert` or `wait_for_async_insert` to `bulk_create`
- **THEN** those values override/merge with the resource defaults in the forwarded list

#### Scenario: Batching and return semantics are unchanged

- **WHEN** `bulk_create` receives `batch_size` and `return_records?`
- **THEN** the system chunks rows by `batch_size` (default 1000, capped at 100_000) and returns a record stream only when `return_records?` is true

### Requirement: Bulk DateTime64 encoding uses fractional Unix seconds

The system SHALL encode `DateTime`/`NaiveDateTime` values for `DateTime64` columns as a quoted decimal Unix-seconds string carrying a microsecond fractional part (for example `"1704164645.123456"`), parsed by ClickHouse's date/time text parser. The form SHALL be timezone-independent and unaffected by numeric-input interpretation settings (such as `input_format_read_datetime_number_as_raw_value`). The column's own precision determines any truncation; microsecond resolution SHALL be preserved.

#### Scenario: DateTime64(6) encodes as fractional seconds

- **WHEN** a datetime is encoded for a `DateTime64(6)` column (the default for `:utc_datetime`, `:naive_datetime`)
- **THEN** the value is a JSON string of the form `"<whole-seconds>.<six-digit-microseconds>"` equal to that datetime's Unix instant, for example `"1704164645.123456"`, or `"1704164645.000000"` when it falls on a whole second

#### Scenario: A DateTime64 value never overflows the column

- **WHEN** a contemporary datetime is encoded for a `DateTime64(N)` column
- **THEN** the value is a quoted decimal-Unix-seconds string that ClickHouse accepts, rather than a JSON number whose meaning changes with the server version or input settings (raw ticks vs seconds)

#### Scenario: All DateTime64 precisions use the same fractional-seconds form

- **WHEN** a datetime is encoded for a `DateTime64(3)`, `DateTime64(6)`, `DateTime64(9)`, or `DateTime64` column
- **THEN** the value is a decimal-Unix-seconds string, identical in form across precisions, and the column's own precision determines any truncation

#### Scenario: A DateTime64 column declared without a precision is still a DateTime64 column

- **WHEN** a datetime is encoded for a `DateTime64` column declared without an explicit precision
- **THEN** the value is a quoted decimal-Unix-seconds string, not a bare integer number of seconds

#### Scenario: Plain DateTime columns encode as integer seconds

- **WHEN** a datetime is encoded for a plain `DateTime` column (no precision suffix)
- **THEN** the value equals `DateTime.to_unix(datetime, :second)`

#### Scenario: A plain DateTime column's integer form is unaffected by numeric-input settings

- **WHEN** a datetime is encoded for a plain `DateTime` column
- **THEN** the bare integer means the same number of seconds whether or not numeric-input interpretation settings such as `input_format_read_datetime_number_as_raw_value` are in effect, because a `DateTime` column's raw underlying value is seconds

#### Scenario: NaiveDateTime converts via UTC before encoding

- **WHEN** a `NaiveDateTime` is encoded for a `DateTime64(N)` column
- **THEN** it is first interpreted as `Etc/UTC` and then encoded as a decimal-Unix-seconds string exactly as the equivalent `DateTime`

#### Scenario: Other bulk temporal encodings are unchanged

- **WHEN** bulk rows contain `Date` or `Time` values
- **THEN** `Date` encodes as days since `1970-01-01` and `Time` encodes as `"HH:MM:SS"`

### Requirement: Bulk create returns records that Ash can match back to their changesets

Records returned by `bulk_create` SHALL carry the bulk reference Ash uses to match a returned record to the changeset that produced it, so a bulk write that asks for its records back completes instead of failing.

#### Scenario: A bulk write that asks for its records completes

- **WHEN** a caller bulk-writes rows and asks for the inserted records back
- **THEN** the call succeeds and returns one record per inserted row

#### Scenario: Returned records can be matched back to the rows that produced them

- **WHEN** a caller bulk-writes rows and asks for the inserted records back
- **THEN** each returned record carries the bulk reference and position Ash uses to find that row's changeset

#### Scenario: Returned records keep the order the rows were submitted in

- **WHEN** a caller bulk-writes several rows and asks for the inserted records back
- **THEN** the returned records appear in the order their rows were submitted

### Requirement: Bulk create returns the values that were submitted

Records returned by `bulk_create` SHALL carry the attribute values that were submitted, not the representation sent to ClickHouse, so a temporal attribute keeps its own type rather than the type the wire format uses.

#### Scenario: A datetime attribute comes back as a datetime

- **WHEN** a row is bulk-written with a UTC datetime attribute
- **THEN** the returned record's attribute is a datetime value equal to the submitted instant

#### Scenario: A naive datetime attribute comes back as a naive datetime

- **WHEN** a row is bulk-written with a naive datetime attribute
- **THEN** the returned record's attribute is a naive datetime value equal to the submitted one

#### Scenario: A date attribute comes back as a date

- **WHEN** a row is bulk-written with a date attribute
- **THEN** the returned record's attribute is a date value equal to the submitted one

#### Scenario: The returned value and the stored value agree to the column's precision

- **WHEN** a row is bulk-written with a datetime attribute and the row is then read back from ClickHouse
- **THEN** the value read back equals the returned record's attribute value to the precision the column stores

#### Scenario: The returned record reflects the submitted row, not a re-read of the stored row

- **WHEN** a row is bulk-written with a column whose value ClickHouse computes itself
- **THEN** the returned record carries no value for that column, matching what the single-record create path returns
