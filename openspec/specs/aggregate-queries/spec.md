# aggregate-queries Specification

## Purpose

Defines the aggregate values the ClickHouse data layer can compute, how an aggregate's own filter and sort narrow the rows it counts, and how aggregates over a related resource are batched into ClickHouse queries.

## Requirements

### Requirement: An aggregate counts only the rows matching its own filter

The system SHALL restrict an aggregate to the rows satisfying that aggregate's own filter, in addition to any filter on the surrounding query, so that a filtered aggregate reports the count of the matching rows rather than of every row.

#### Scenario: A filtered count counts only matching rows

- **WHEN** a count aggregate declares a filter and the queried rows include both matching and non-matching rows
- **THEN** the aggregate's value is the count of the matching rows only

#### Scenario: A filtered count differs from an unfiltered count over the same rows

- **WHEN** two count aggregates over the same rows differ only in their filter
- **THEN** their values differ when the filter excludes some rows

#### Scenario: A filtered count over no matching rows is zero

- **WHEN** a count aggregate's filter matches no rows
- **THEN** the aggregate's value is zero rather than null or absent

#### Scenario: A filtered sum totals only matching rows

- **WHEN** a sum aggregate declares a filter
- **THEN** the aggregate's value is the sum of the matching rows' values only

#### Scenario: An aggregate's filter is combined with the query's filter

- **WHEN** a query carries a filter and an aggregate carries its own filter
- **THEN** the aggregate's value reflects only the rows satisfying both

### Requirement: An aggregate honours its own sort

The system SHALL order the rows an aggregate considers by that aggregate's own sort before determining its value, for the aggregate kinds whose value depends on row order.

#### Scenario: A first aggregate with a sort returns the first matching row

- **WHEN** a first aggregate declares a sort and several rows match
- **THEN** the aggregate's value is the field of the row that comes first under that sort

#### Scenario: A first aggregate's sort direction is honoured

- **WHEN** a first aggregate declares a descending sort and several rows match
- **THEN** the aggregate's value is the field of the row with the greatest value under that sort

#### Scenario: A list aggregate with a sort returns its rows in that order

- **WHEN** a list aggregate declares a sort
- **THEN** the aggregate's value lists the matching rows' fields in the sorted order

### Requirement: The layer supports the aggregate kinds ClickHouse expresses

The system SHALL support the count, sum, average, minimum and maximum aggregate kinds, and SHALL additionally support the first, list and existence kinds, reporting support for each kind it supports and refusing the ones it does not.

#### Scenario: The basic aggregate kinds are supported

- **WHEN** the layer is asked whether it supports a count, sum, average, minimum or maximum aggregate
- **THEN** it reports support

#### Scenario: The first, list and existence aggregate kinds are supported

- **WHEN** the layer is asked whether it supports a first, list or existence aggregate
- **THEN** it reports support

#### Scenario: An unsupported aggregate kind is refused

- **WHEN** the layer is asked whether it supports an aggregate kind it cannot compute
- **THEN** it reports non-support

#### Scenario: A first aggregate returns a single field value

- **WHEN** a caller requests a first aggregate over rows that match
- **THEN** the aggregate's value is the field of a single matching row

#### Scenario: A first aggregate over no matching rows falls back

- **WHEN** a caller requests a first aggregate and no row matches
- **THEN** the aggregate's value is the aggregate's declared default

#### Scenario: A list aggregate returns every matching field value

- **WHEN** a caller requests a list aggregate over several matching rows
- **THEN** the aggregate's value carries the field value of each matching row

#### Scenario: An existence aggregate reports whether any row matched

- **WHEN** a caller requests an existence aggregate
- **THEN** the aggregate's value reports whether any row matched the aggregate's filter

### Requirement: An aggregate over a related resource is computed with one query

The system SHALL compute an aggregate over a related resource using a single grouped ClickHouse query for the whole result set, and SHALL issue that query once per aggregate regardless of how many records are returned.

#### Scenario: An aggregate over a relationship is reported as supported

- **WHEN** the layer is asked whether it supports aggregating over a relationship
- **THEN** it reports support

#### Scenario: A relationship aggregate is declared without error

- **WHEN** a resource declares an aggregate over one of its relationships
- **THEN** the resource compiles, rather than being rejected as not aggregatable

#### Scenario: A relationship aggregate's value is attached to each record

- **WHEN** a caller reads records and loads an aggregate over a relationship
- **THEN** each returned record carries that aggregate's value for its own related rows

#### Scenario: A relationship aggregate issues one query for the whole result set

- **WHEN** a caller reads many records and loads an aggregate over a relationship
- **THEN** the number of queries issued for that aggregate does not grow with the number of records returned

#### Scenario: A relationship aggregate is issued once, not twice

- **WHEN** a caller reads records and loads an aggregate over a relationship
- **THEN** the aggregate's value is computed by exactly one query, and the value is not computed twice

#### Scenario: A relationship aggregate's filter narrows the counted rows

- **WHEN** a relationship aggregate declares a filter and a record has both matching and non-matching related rows
- **THEN** that record's aggregate value counts only the matching related rows

#### Scenario: A relationship aggregate over a record with no related rows falls back

- **WHEN** a record has no related rows for an aggregate over a relationship
- **THEN** that record's aggregate value is the aggregate's declared default

### Requirement: Records can be sorted by an aggregate

The system SHALL order a query's results by an aggregate's value, using the computed aggregate rather than treating the aggregate as an ordering key with no value.

#### Scenario: A sort by an aggregate is accepted

- **WHEN** a caller sorts a query by an aggregate
- **THEN** the query is valid and the results are ordered by the aggregate's value

#### Scenario: A sort by an aggregate does not change which rows are returned

- **WHEN** a caller sorts a query by an aggregate
- **THEN** the same set of rows is returned as the same query without the sort
