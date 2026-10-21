# Spec Delta

## Purpose

Defines the query-level options the ClickHouse data layer honours — how distinct results are selected, how long a query may run, and how many rows a bulk write sends at a time — and how each maps onto ClickHouse's own behaviour.

## ADDED Requirements

### Requirement: Distinct results are selected by the requested order

The system SHALL support selecting distinct records in the order the caller requests, choosing among records that share a distinct value by that order rather than by an arbitrary one.

#### Scenario: A distinct sort is accepted

- **WHEN** a caller sets a distinct sort on a query
- **THEN** the query is valid and the distinct sort is accepted rather than refused

#### Scenario: A distinct sort selects one record per distinct value

- **WHEN** a caller sets a distinct sort and several records share a distinct value
- **THEN** one record per distinct value is returned

#### Scenario: A distinct sort determines which record is chosen

- **WHEN** a caller sets a distinct sort and several records share a distinct value but differ in the sorted field
- **THEN** the record chosen is the one that comes first under that sort

#### Scenario: A distinct sort's direction is honoured

- **WHEN** a caller sets a descending distinct sort
- **THEN** the record chosen for a distinct value is the one with the greatest value under that sort

#### Scenario: A distinct sort does not change which distinct values are returned

- **WHEN** a caller sets a distinct sort
- **THEN** the same set of distinct values is returned as the same query without the distinct sort

#### Scenario: The distinct sort is reported as supported

- **WHEN** the layer is asked whether it supports a distinct sort
- **THEN** it reports support

### Requirement: A query timeout bounds how long the database may run it

The system SHALL accept a query timeout and SHALL apply it to the database request, so that a query exceeding its timeout is stopped by the database rather than running to completion.

#### Scenario: A timeout is accepted

- **WHEN** a caller sets a timeout on a query
- **THEN** the query is valid and the timeout is accepted rather than refused

#### Scenario: The timeout is applied to the database request

- **WHEN** a caller sets a timeout on a query
- **THEN** the request to the database carries that timeout

#### Scenario: A query exceeding its timeout is stopped

- **WHEN** a query's timeout elapses before the database finishes it
- **THEN** the query fails with a timeout error rather than returning a partial or complete result

#### Scenario: A query within its timeout succeeds

- **WHEN** a query completes within its timeout
- **THEN** the query succeeds and returns its results

#### Scenario: The timeout is reported as supported

- **WHEN** the layer is asked whether it supports a query timeout
- **THEN** it reports support

### Requirement: The bulk write batch size is declared to the framework

The system SHALL declare the number of rows it writes per batch, so that the framework groups the rows it hands over into batches of that size rather than dividing the write into batches of a different size.

#### Scenario: The declared batch size is reported

- **WHEN** the framework asks the layer for its default batch size
- **THEN** the layer reports the size it writes rows in

#### Scenario: The rows of a bulk write are grouped into the declared size

- **WHEN** a caller bulk-writes more rows than the declared batch size
- **THEN** the rows are sent to the database in groups of that size

#### Scenario: A caller-specified batch size takes precedence

- **WHEN** a caller bulk-writes with an explicit batch size
- **THEN** the rows are sent in groups of the caller's size rather than the declared one
