# Spec Delta

## Purpose

Defines how the ClickHouse data layer answers queries that reach across a relationship — filtering by a related resource's attributes, and aggregating over a related resource — using semi-joins that preserve the number of rows a query returns.

## ADDED Requirements

### Requirement: A filter across a relationship selects the rows with a matching related row

The system SHALL answer a filter that references a related resource's attributes by selecting the queried rows that have at least one related row satisfying the filter, using a semi-join so that the number of returned rows does not depend on how many related rows match.

#### Scenario: Only rows with a matching related row are returned

- **WHEN** a query filters the queried resource by an attribute of its related resource
- **THEN** the returned rows are exactly those having at least one related row matching the filter

#### Scenario: A matching related row is enough

- **WHEN** a row has one related row matching the filter and another that does not
- **THEN** the row is returned

#### Scenario: A row without a matching related row is excluded

- **WHEN** a row's related rows all fail the filter
- **THEN** the row is not returned

#### Scenario: A row is returned once however many related rows match

- **WHEN** a row has several related rows matching the filter
- **THEN** the row appears exactly once in the result

#### Scenario: The result count matches the filter's intent

- **WHEN** a query filters across a relationship and the result is counted
- **THEN** the count equals the number of queried rows with a matching related row, not the number of matching related rows

#### Scenario: A filter across a relationship combines with the query's own filter

- **WHEN** a query carries both a filter on its own attributes and a filter across a relationship
- **THEN** the returned rows satisfy both filters

#### Scenario: A filter across a relationship reports support

- **WHEN** the layer is asked whether it supports filtering by a relationship's attributes
- **THEN** it reports support, so that a query naming those attributes is accepted

#### Scenario: A filter across a relationship that cannot be expressed is refused

- **WHEN** a caller builds a query whose filter crosses a relationship in a way the layer cannot express
- **THEN** the query is invalid and carries an error, and no query is sent to the database

### Requirement: An aggregate over a relationship is computed per row

The system SHALL attach to each returned row the value of an aggregate over that row's related rows, computed against the related resource's own attributes and the aggregate's own filter.

#### Scenario: An aggregate over a relationship is reported as supported

- **WHEN** the layer is asked whether it supports aggregating over a relationship
- **THEN** it reports support

#### Scenario: An aggregate over a relationship is attached to each row

- **WHEN** a caller loads an aggregate over a relationship while reading
- **THEN** each returned row carries the aggregate's value computed from that row's related rows

#### Scenario: An aggregate over a relationship counts the row's own related rows

- **WHEN** a count aggregate over a relationship is loaded, and one row has three related rows and another has one
- **THEN** the first row's aggregate value is three and the second's is one

#### Scenario: An aggregate over a relationship honours its own filter

- **WHEN** an aggregate over a relationship declares a filter
- **THEN** only the related rows matching that filter are counted

#### Scenario: An aggregate over a relationship honours its own sort

- **WHEN** a first aggregate over a relationship declares a sort
- **THEN** the value comes from the related row that comes first under that sort

#### Scenario: An aggregate over a relationship falls back for a row with no related rows

- **WHEN** a returned row has no related rows for the aggregate
- **THEN** that row's aggregate value is the aggregate's declared default

#### Scenario: An aggregate over a relationship is computed once for the whole result set

- **WHEN** a caller reads many rows and loads an aggregate over a relationship
- **THEN** the aggregate's value is computed by exactly one query, and the number of queries does not grow with the number of rows returned
