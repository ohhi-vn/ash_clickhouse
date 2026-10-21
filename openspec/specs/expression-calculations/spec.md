# expression-calculations Specification

## Purpose

Defines how the ClickHouse data layer evaluates Ash expression calculations — the values derived from a resource's own attributes by an expression rather than stored — including evaluating them in the database and reporting the values back on the returned records.

## Requirements

### Requirement: Expression calculations are evaluated by the data layer

The system SHALL evaluate an expression calculation as part of the database query that produces the records, rather than refusing the query or leaving the calculated value absent from the result.

#### Scenario: A read of a resource with an expression calculation completes

- **WHEN** a caller reads a resource that declares an expression calculation
- **THEN** the read completes and returns records, rather than failing

#### Scenario: The calculated value is present on the returned record

- **WHEN** a caller reads a resource with an expression calculation
- **THEN** each returned record carries the calculated value under the calculation's name

#### Scenario: The calculated value reflects the stored attributes

- **WHEN** an expression calculation derives a value from an attribute, and the record is read back
- **THEN** the calculated value equals what that expression yields from the stored attribute value

#### Scenario: A calculation over a numeric attribute yields a numeric value

- **WHEN** an expression calculation derives a number from a numeric attribute
- **THEN** the calculated value is a number rather than a string representation of one

#### Scenario: Several expression calculations are evaluated together

- **WHEN** a caller reads a resource that declares more than one expression calculation
- **THEN** each returned record carries every calculated value, and the read issues one query for the records rather than one query per calculation

#### Scenario: The expression's own type constraint is applied

- **WHEN** an expression calculation declares a type, and the derived value does not satisfy it
- **THEN** the calculated value is cast or rejected according to that type, consistently with how a stored attribute of the same type behaves

### Requirement: A one-off calculation is evaluated against the record it belongs to

The system SHALL evaluate a standalone expression request against the record it is asked about, and SHALL report the value the expression yields for that record.

#### Scenario: A one-off calculation returns the record's value

- **WHEN** a caller asks the data layer to evaluate an expression for a particular record
- **THEN** the result is the value the expression yields for that record

#### Scenario: A one-off calculation over several expressions returns one value per expression

- **WHEN** a caller asks the data layer to evaluate several expressions at once
- **THEN** the result carries one value per expression, in the order requested

#### Scenario: A one-off calculation that cannot be evaluated reports an error

- **WHEN** a caller asks the data layer to evaluate an expression that cannot be evaluated against the record
- **THEN** an error is reported and no value is invented

### Requirement: Records can be sorted by an expression calculation

The system SHALL order a query's results by the value of an expression calculation, using the calculated value rather than treating the calculation as an ordering key with no value.

#### Scenario: A sort by an expression calculation is accepted

- **WHEN** a caller sorts a query by an expression calculation
- **THEN** the query is valid and the results are ordered by the calculated value

#### Scenario: A sort by an expression calculation orders the results

- **WHEN** a caller sorts a query by an expression calculation and reads it
- **THEN** the returned records are ordered by that calculation's value, in the requested direction

#### Scenario: A sort by an expression calculation does not change which rows are returned

- **WHEN** a caller sorts a query by an expression calculation
- **THEN** the same set of rows is returned as the same query without the sort
