# filter-expressions Specification

## Purpose

Defines which Ash filter expressions the ClickHouse data layer can express as SQL predicates, how each is translated, and how the layer reports the expressions it supports so that unsupported filters are rejected before a query is issued.

## Requirements

### Requirement: Filter expressions are translated to ClickHouse predicates

The system SHALL translate a supported Ash filter expression into an equivalent ClickHouse `WHERE` predicate, preserving the expression's semantics, and SHALL bind literal values as query parameters rather than interpolating them into the SQL text.

#### Scenario: A string inequality is translated

- **WHEN** a filter compares an attribute for inequality, such as `name != "bob"`
- **THEN** the predicate compares the attribute to a bound parameter using inequality, and the query completes

#### Scenario: An equality filter is translated

- **WHEN** a filter compares an attribute for equality, such as `age == 30`
- **THEN** the predicate compares the attribute to a bound parameter using equality

#### Scenario: A range comparison is translated

- **WHEN** a filter compares an attribute with `>`, `>=`, `<`, or `<=`
- **THEN** the predicate compares the attribute to a bound parameter using the same operator

#### Scenario: A membership filter is translated

- **WHEN** a filter tests membership, such as `age in [1, 2, 3]`
- **THEN** the predicate tests membership against one bound parameter per listed value

#### Scenario: A null test is translated

- **WHEN** a filter tests an attribute for null, such as `is_nil(name)`
- **THEN** the predicate tests the attribute for null using the database's null comparison

#### Scenario: A negated membership filter is translated

- **WHEN** a filter tests non-membership, such as `age not in [1, 2]`
- **THEN** the predicate tests non-membership against one bound parameter per listed value

#### Scenario: A conjunction is translated

- **WHEN** a filter combines predicates with `and`
- **THEN** the predicate combines the translated operands with a logical conjunction, parenthesised so the grouping is preserved

#### Scenario: A disjunction is translated

- **WHEN** a filter combines predicates with `or`
- **THEN** the predicate combines the translated operands with a logical disjunction, parenthesised so the grouping is preserved

#### Scenario: A negation is translated

- **WHEN** a filter negates a predicate
- **THEN** the predicate negates the translated operand

#### Scenario: Literal values are bound, not interpolated

- **WHEN** a filter compares an attribute against a literal string
- **THEN** the literal is passed to the database as a bound parameter and does not appear in the SQL text

### Requirement: Function-shaped filters are translated to ClickHouse functions

The system SHALL translate the Ash filter function forms that have a ClickHouse equivalent into an equivalent ClickHouse predicate, and SHALL bind the function's literal arguments as query parameters.

#### Scenario: A containment filter is translated

- **WHEN** a filter tests whether a string attribute contains a substring, such as `contains(name, "bo")`
- **THEN** the predicate performs a substring search against a bound parameter

#### Scenario: A prefix filter is translated

- **WHEN** a filter tests whether a string attribute starts with a prefix, such as `string_starts_with(name, "bo")`
- **THEN** the predicate matches the attribute against the prefix, treating wildcard characters in the prefix literally

#### Scenario: A suffix filter is translated

- **WHEN** a filter tests whether a string attribute ends with a suffix, such as `string_ends_with(name, "ob")`
- **THEN** the predicate matches the attribute against the suffix, treating wildcard characters in the suffix literally

#### Scenario: An array membership filter is translated

- **WHEN** a filter tests whether an array attribute contains a value, such as `has(tags, "a")`
- **THEN** the predicate tests the array for membership of a bound parameter

#### Scenario: An array intersection filter is translated

- **WHEN** a filter tests whether two array attributes intersect, such as `intersects(a, b)`
- **THEN** the predicate tests the two arrays for a common element

#### Scenario: A null-test function is translated

- **WHEN** a filter tests an attribute for null using the function form
- **THEN** the predicate tests the attribute for null using the database's null comparison

### Requirement: The layer reports exactly the filter expressions it can express

The system SHALL report support for a filter expression only when it can translate that expression into a ClickHouse predicate, and SHALL report non-support otherwise, so that an unsupported filter is refused when the query is built rather than failing part-way through execution.

#### Scenario: A supported expression is reported as supported

- **WHEN** the layer is asked whether it supports an operator or function it can translate
- **THEN** it reports support

#### Scenario: An unsupported expression is reported as unsupported

- **WHEN** the layer is asked whether it supports an operator or function it cannot translate
- **THEN** it reports non-support

#### Scenario: An unsupported filter is refused when the query is built

- **WHEN** a caller builds a query whose filter uses an expression the layer cannot translate
- **THEN** the query is invalid and carries an error naming the unsupported expression, and no query is sent to the database

#### Scenario: A supported filter is accepted when the query is built

- **WHEN** a caller builds a query whose filter uses only expressions the layer can translate
- **THEN** the query is valid

### Requirement: A filter on a related resource is translated to a semi-join

The system SHALL translate a filter that references an attribute of a related resource into a ClickHouse predicate that selects the rows of the queried resource having at least one matching related row, without changing how many rows the query returns.

#### Scenario: A filter across a relationship is translated

- **WHEN** a filter references an attribute of a related resource, such as filtering customers by an order's status
- **THEN** the predicate tests the queried resource's key against the related resource's rows matching the filter

#### Scenario: A filter across a relationship does not duplicate rows

- **WHEN** a filter across a relationship matches several related rows for one queried row
- **THEN** that queried row appears once in the result, not once per matching related row

#### Scenario: A filter across a relationship is reported as supported

- **WHEN** the layer is asked whether it supports filtering by a relationship's attributes
- **THEN** it reports support

#### Scenario: A filter across a relationship is refused when the query is built

- **WHEN** a caller builds a query whose filter references a related resource's attributes and the layer cannot express it
- **THEN** the query is invalid and carries an error, and no query is sent to the database

### Requirement: An existence check over an unrelated resource is translated

The system SHALL translate an existence check that names a resource other than the one being queried into a ClickHouse predicate testing whether any row of that resource satisfies the check.

#### Scenario: An unrelated existence check is translated

- **WHEN** a filter checks whether any row of an unrelated resource satisfies a condition
- **THEN** the predicate tests for the existence of such a row

#### Scenario: An unrelated existence check is reported as supported

- **WHEN** the layer is asked whether it supports existence checks over an unrelated resource
- **THEN** it reports support

### Requirement: The layer publishes the ClickHouse functions available in filters

The system SHALL publish, for use in filters, the set of functions that map onto ClickHouse SQL functions and are not already provided by Ash, so that a caller can filter on ClickHouse-specific expressions.

#### Scenario: A published function is usable in a filter

- **WHEN** a caller writes a filter that calls one of the layer's published functions
- **THEN** the query is valid and the function is translated into its ClickHouse equivalent

#### Scenario: An unpublished function is refused

- **WHEN** a caller writes a filter that calls a function the layer does not publish
- **THEN** the query is invalid and carries an error naming the unknown function
