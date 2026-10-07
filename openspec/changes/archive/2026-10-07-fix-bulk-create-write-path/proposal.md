# Proposal

## Why

In 0.7.3 `Ash.bulk_create/4` cannot write to ClickHouse: the data layer forwards Ash's internal bulk options into the ClickHouse client option list (which the client rejects) and its `DateTime64` bulk encoding ignores column precision (always microseconds), so non-`(6)` columns overflow or land in 1970. Downstream `ClickhouseExLogger.Insert` works around both defects; fixing upstream lets that workaround collapse to plain `Ash.bulk_create/4` with no behavioural change.

## What Changes

- Sanitize `bulk_create/3` client options: only forward ClickHouse-recognized insert options (`async_insert`, `wait_for_async_insert`, plus resource `insert_opts` and explicit `database` passthrough) to `repo.insert_rows/3`; keep consuming `batch_size` and `return_records?` locally and drop all other Ash bulk keys.
- Make bulk `DateTime64` encoding precision-aware: parse `N` from the resolved column type (`DateTime64(N[, tz])`) and scale the Unix timestamp to `10^N` ticks (3 → ms, 6 → µs, 9 → ns); keep `DateTime` as epoch seconds, `Date` as days, `Time` as string.
- Keep the public building blocks (`Insert.build_insert_rows/2`, `Insert.insert_statement/2`, `Insert.insert_opts/2`, `Insert.encode_*`) as the single source of truth for table/encoding so the resource stays authoritative.
- Add/adjust unit coverage for option filtering and precision scaling; no API or config shape change.

## Capabilities

### New Capabilities

- `bulk-create`: Ash `bulk_create` write path to ClickHouse — batching, client-option sanitization, and bulk value encoding (including precision-aware `DateTime64`) so `Ash.bulk_create/4` succeeds against real ClickHouse.

### Modified Capabilities

_No existing specs — `openspec/specs/` is empty, so there is nothing to modify._

## Impact

- Affected code: `AshClickhouse.DataLayer.bulk_create/3`, `AshClickhouse.DataLayer.Insert` (`insert_opts/2`, `encode_datetime/2`), `AshClickhouse.Connection.insert_rows/4` docs.
- APIs: no breaking change; `bulk_create` and `insert_rows` signatures unchanged, only the forwarded option set and encoded values change to what ClickHouse already expects.
- Dependencies/systems: `clickhouse ~> 0.32`, `ash ~> 3.33` unchanged; ClickHouse server behaviour unchanged (fixes interpretation as raw scaled `DateTime64` ticks per precision).
