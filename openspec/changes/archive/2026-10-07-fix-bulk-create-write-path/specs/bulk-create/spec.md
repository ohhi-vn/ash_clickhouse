# Spec Delta

## Purpose

Makes Ash bulk inserts a reliable write path to ClickHouse so callers can use `Ash.bulk_create/4` directly instead of a downstream workaround module.

## ADDED Requirements

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

### Requirement: Bulk DateTime64 encoding respects column precision

The system SHALL encode bulk `DateTime`/`NaiveDateTime` values as raw scaled `DateTime64` ticks matching the resolved column precision.

#### Scenario: DateTime64(6) encodes as microseconds

- **WHEN** a datetime is encoded for a `DateTime64(6)` column (the default for `:utc_datetime`, `:naive_datetime`)
- **THEN** the value equals `DateTime.to_unix(datetime, :microsecond)`

#### Scenario: DateTime64(3) encodes as milliseconds

- **WHEN** a datetime is encoded for a `DateTime64(3)` column
- **THEN** the value equals `div(DateTime.to_unix(datetime, :microsecond), 1000)` and does not overflow the `DateTime64(3)` range for ordinary contemporary timestamps

#### Scenario: DateTime64(9) encodes as nanoseconds

- **WHEN** a datetime is encoded for a `DateTime64(9)` column
- **THEN** the value equals `DateTime.to_unix(datetime, :nanosecond)`

#### Scenario: Plain DateTime columns encode as seconds

- **WHEN** a datetime is encoded for a plain `DateTime` column (no precision suffix)
- **THEN** the value equals `DateTime.to_unix(datetime, :second)`

#### Scenario: NaiveDateTime converts via UTC before scaling

- **WHEN** a `NaiveDateTime` is encoded for a `DateTime64(N)` column
- **THEN** it is first interpreted as `Etc/UTC` and then scaled by `10^N` exactly as the equivalent `DateTime`

#### Scenario: Other bulk temporal encodings are unchanged

- **WHEN** bulk rows contain `Date` or `Time` values
- **THEN** `Date` encodes as days since `1970-01-01` and `Time` encodes as `"HH:MM:SS"`
