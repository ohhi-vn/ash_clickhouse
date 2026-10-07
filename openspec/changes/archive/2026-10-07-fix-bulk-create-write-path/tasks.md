# Tasks

## 1. Option sanitization

- [x] 1.1 Allowlist client insert options in `Insert.insert_opts/2` and verify `Insert.insert_opts(res, [return_records?: true, batch_size: 5, authorize?: true, async_insert: 1])` forwards only allowlisted keys
- [x] 1.2 Confirm `DataLayer.bulk_create/3` still consumes `batch_size`/`return_records?` locally and verify chunking + empty-stream behaviour via existing `data_layer_edge_test.exs` bulk cases
- [x] 1.3 Update `Connection.insert_rows/4` docs with the forwarded option set and verify `mix docs` builds without warnings (or doc grep passes)

## 2. Precision-aware DateTime64 encoding

- [x] 2.1 Scale `encode_datetime/2` by parsed `DateTime64(N)` precision (3→ms, 6→µs, 9→ns, generic `10^N`) and verify unit assertions for `(3)`, `(6)`, `(9)` plus plain `DateTime` seconds
- [x] 2.2 Cover `NaiveDateTime` via `Etc/UTC` conversion for each precision and verify parity with the equivalent `DateTime` encoding
- [x] 2.3 Fix the misleading `SecondPrecisionDateTimeResource` fixture/expectation in `coverage_gaps_test.exs` and verify the corrected test passes

## 3. Verification

- [x] 3.1 Run unit suite excluding integration (`mix test --exclude integration`) and verify green
- [x] 3.2 Run `mix format --check-formatted` and `mix credo --strict` on touched files and verify clean
- [x] 3.3 Validate planning artifacts (`openspec validate --change fix-bulk-create-write-path --strict`) and verify no errors
