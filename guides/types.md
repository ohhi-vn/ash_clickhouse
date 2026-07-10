# Type Mapping

ClickHouse is a strongly-typed columnar store. AshClickhouse maps Ash attribute
types to ClickHouse column types when generating `CREATE TABLE` statements and
when encoding query parameters.

The mapping lives in `AshClickhouse.DataLayer.Types`.

## Ash → ClickHouse

| Ash type | ClickHouse type |
| --- | --- |
| `:uuid` / `Type.UUID` | `UUID` |
| `:string` / `:text` / `:atom` / `:ci_string` / `Type.String` / `Type.Atom` / `Type.CiString` / `Type.Binary` | `String` |
| `:integer` / `Type.Integer` | `Int64` |
| `:float` / `:double` / `Type.Float` | `Float64` |
| `:boolean` / `Type.Boolean` | `UInt8` |
| `:utc_datetime` / `:utc_datetime_usec` / `Type.DateTime` | `DateTime64(6)` |
| `:naive_datetime` | `DateTime64(6)` |
| `:date` / `Type.Date` | `Date` |
| `:time` / `Type.Time` | `String` |
| `:decimal` / `Type.Decimal` | `Decimal(38, 10)` |
| `:map` / `Type.Map` | `Map(String, String)` |
| `:array` / `:list` | `Array(String)` |

## Encoding notes

- UUIDs are encoded/decoded as hex strings and wrapped in ClickHouse `UUID`
  literals where needed.
- `UInt8` is used for booleans (ClickHouse has no native boolean type).
- `Decimal` uses a fixed precision/scale of `Decimal(38, 10)`.
- `Map` and `Array` use the simplest safe ClickHouse representations
  (`Map(String, String)` and `Array(String)`).

## Extending the mapping

The mapping is a set of `def ash_type_to_clickhouse/1` clauses. If you need a
different ClickHouse type for a custom Ash type, you can add a clause in your
own code or open an issue/PR to extend `AshClickhouse.DataLayer.Types`.
