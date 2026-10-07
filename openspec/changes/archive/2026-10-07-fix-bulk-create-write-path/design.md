# Design

## Context

See `proposal.md` for motivation. Current state (observed in `lib/`):

- `DataLayer.bulk_create/3` normalizes `opts` (map→list), consumes `batch_size`/`return_records?` locally, then calls `Insert.insert_opts(resource, opts)` and forwards the result verbatim to `repo.insert_rows/3` → `Connection.insert_rows/4` → `ClickHouse.query/4`.
- `Insert.insert_opts/2` is `Keyword.merge(Dsl.insert_opts(resource), opts)` plus `maybe_put` for the two async keys — i.e. every Ash bulk key (`return_records?`, `return_errors?`, `authorize?`, `tenant`, `tracer`, `action`, …) leaks into client opts, which the client rejects.
- `Insert.encode_datetime/2` branches only on the `"DateTime64("` prefix and always returns `DateTime.to_unix(dt, :microsecond)`. `Types.resolve_attr_type/1` can yield `DateTime64(3|6|9[, tz])` (default `DateTime64(6)` for datetime Ash types), so any non-6 precision column receives a wrongly-scaled integer: `DateTime64(3)` overflows/out-of-range, `DateTime64(9)` lands near 1970. `NaiveDateTime` is converted via `Etc/UTC` first — that part is correct and stays.

## Goals / Non-Goals

**Goals:**

- Make `Ash.bulk_create/4` succeed with default and explicit insert options.
- Make bulk datetime encoding correct for all `DateTime64` precisions without changing the default `(6)` value.
- Keep `Insert.*` as the single encoding/statement source so downstream `ClickhouseExLogger.Insert` can collapse to `Ash.bulk_create/4`.

**Non-Goals:**

- No new DSL keys, repo API, or table/engine changes.
- No change to single-row `create/update/destroy`, reads, streams, or aggregates.
- No ClickHouse-server version gating (raw scaled ticks are correct on both pre- and post-26.8 JSON-number semantics).

## Decisions

### 1. Allowlist client insert options in `Insert.insert_opts/2`

Filter the merged keyword list to only `[:async_insert, :wait_for_async_insert]` plus an explicit `:database` passthrough (and `:settings` if already present — `Connection` already threads `:database`/`:default_format` itself). `DataLayer.bulk_create/3` keeps consuming `batch_size`/`return_records?` locally; everything else is dropped before `insert_rows`.

- Alternative considered: blocklist known Ash keys. Rejected — Ash adds keys across versions; an allowlist is stable and matches the client's narrow contract (`Connection.insert_rows/4` docs already say "e.g. `async_insert`/`wait_for_async_insert`").
- Alternative considered: filter in `DataLayer.bulk_create/3` only. Rejected — `Insert.insert_opts/2` is the documented building block downstream reuse; the invariant ("only client keys leave this function") belongs there.

### 2. Precision-aware `encode_datetime/2`

Parse `N` with `~r/DateTime64\((\d+)/` on `Types.resolve_attr_type(attr)`:

- `N = 3` → `DateTime.to_unix(dt, :millisecond)` (equivalently `div(micro, 1_000)`).
- `N = 6` → `DateTime.to_unix(dt, :microsecond)` (current behaviour, covered by existing tests).
- `N = 9` → `DateTime.to_unix(dt, :nanosecond)`.
- Other `N` (0–9) → scale `micro * 10^(N-6)` via integer pow (divide when `N < 6`); unparseable/missing → fall back to seconds for plain `DateTime`, matching today's fallback.

`NaiveDateTime` keeps the existing `DateTime.from_naive(v, "Etc/UTC")` step, then shares the same scaler. `Date` (days) and `Time` (string) paths are untouched.

### 3. Keep signatures stable

No signature changes to `bulk_create/3`, `insert_rows/3`, `build_insert_rows/2`, or `insert_statement/2`. Existing unit fakes that ignore `opts` (`_opts`) keep passing; new tests assert on the recorded `opts`.

## Risks / Trade-offs

- [Risk] Existing test `coverage_gaps_test.exs` names a `SecondPrecisionDateTimeResource` but both fixtures use `:utc_datetime` → `DateTime64(6)`, and one assertion expects micros while commenting "seconds" → Mitigation: fix the fixture to a true second-precision type (custom `storage_type`) or correct the expectation; add explicit `(3)`/`(9)` fixtures.
- [Risk] Unknown extra client settings a user passes through `bulk_create` get dropped by the allowlist → Mitigation: document the forwarded set in `Connection.insert_rows/4` and `guides/querying.md`; users needing raw settings use `repo.insert_rows/3` directly.
- [Risk] Pre-26.8 vs post-26.8 server JSON-number interpretation confusion → Mitigation: raw scaled integers are the documented `DateTime64` tick representation on both; no version branch needed.

## Migration Plan

- Pure bug fix, no data migration. Deploy as patch (`0.7.4`).
- Rollback: revert; downstream workaround module resumes working unchanged since it uses the same building blocks.
- Docs: update `Connection.insert_rows/4` `@doc` forwarded-options line and the `bulk_create` paragraph in `guides/querying.md`.

## Open Questions

None — precision mapping and allowlist contents are decided above. If review surfaces an additional client-recognized insert key, add it to the allowlist without changing specs or task breakdown.
