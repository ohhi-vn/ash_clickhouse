# Spec Delta

## ADDED Requirements

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
