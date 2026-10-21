# combination-queries Specification

## Purpose

Defines how the ClickHouse data layer runs a query that combines several queries — unioning their results — as a single statement against the database.

## Requirements

### Requirement: A combination query is run as one statement

The system SHALL run a combination query as a single statement against the database that unions the results of the combined queries, rather than running each query separately and combining the results in the application.

#### Scenario: A union query completes

- **WHEN** a caller reads a query that unions two queries
- **THEN** the read completes and returns the combined results

#### Scenario: The combined results contain each query's rows

- **WHEN** a caller unions a query matching two rows with a query matching one different row
- **THEN** the result contains all three rows

#### Scenario: A union query is issued to the database once

- **WHEN** a caller reads a query that unions two queries
- **THEN** one statement is issued to the database for the combined read

#### Scenario: Each combined query keeps its own filter

- **WHEN** a caller unions two queries that carry different filters
- **THEN** each query contributes only the rows matching its own filter

#### Scenario: Each combined query keeps its own limit

- **WHEN** a caller unions two queries that each declare a limit
- **THEN** each query contributes at most its own limit's worth of rows

#### Scenario: Each combined query keeps its own sort

- **WHEN** a caller unions two queries that each declare a sort
- **THEN** each query contributes its rows in its own sorted order

#### Scenario: A union keeps duplicate rows

- **WHEN** a caller unions two queries whose results contain the same row
- **THEN** that row appears once per query that produced it

#### Scenario: A deduplicating union removes duplicate rows

- **WHEN** a caller unions two queries whose results contain the same row and asks for duplicates to be discarded
- **THEN** that row appears once

### Requirement: The layer reports which combination kinds it supports

The system SHALL report support for the combination kinds it can run, and SHALL refuse the ones it cannot, so that an unsupported combination is refused before the query is issued.

#### Scenario: Combining queries is reported as supported

- **WHEN** the layer is asked whether it supports combining queries
- **THEN** it reports support

#### Scenario: Concatenating union is reported as supported

- **WHEN** the layer is asked whether it supports the combination kind that keeps duplicates
- **THEN** it reports support

#### Scenario: An unsupported combination kind is refused

- **WHEN** the layer is asked whether it supports a combination kind it cannot run
- **THEN** it reports non-support, and a query using that kind is refused before it is issued

### Requirement: A combination query reports its results in the order the combined queries produced them

The system SHALL return the rows of a combination query in the order the combined queries produced them, so that a caller relying on that order — such as one that reads the first row — sees the expected row.

#### Scenario: The first row of a combination is the first row of the first query

- **WHEN** a caller unions two queries and reads the first row
- **THEN** that row is the first row of the first combined query

#### Scenario: Rows keep the order of the query that produced them

- **WHEN** a caller unions two queries each returning several rows
- **THEN** the result lists the first query's rows, in its order, followed by the second query's rows, in its order
